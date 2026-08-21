// Runs the four web tracking pipelines in real headless Chrome and prints
// the in-page proof line. The corpus stills and model bundles are gitignored
// fetch outputs, materialized here from .models so a fresh clone proves
// without a manual copy step; the wasm and bundled worker come from the build.

const here = new URL(".", import.meta.url);
const models = new URL("../../../.models/", import.meta.url);
const assets: Array<[string, string]> = [
  ["../zig-out/wasm/gosslens_tracking.wasm", "gosslens_tracking.wasm"],
  ["face_landmarker.task", "face_landmarker.task"],
  ["pose_landmarker_full.task", "pose_landmarker_full.task"],
  ["gesture_recognizer.task", "gesture_recognizer.task"],
  ["selfie_multiclass.tflite", "selfie_multiclass.tflite"],
  ["corpus/face_frontal_b.jpg", "face_frontal_b.jpg"],
  ["corpus/no_face_control.jpg", "no_face_control.jpg"],
  ["corpus/hand_raised.jpg", "hand_raised.jpg"],
  ["corpus/body_standing.jpg", "body_standing.jpg"],
];
for (const [from, to] of assets) {
  await Bun.write(new URL(to, here), Bun.file(new URL(from, models)));
}

const port = 8933;
const server = Bun.spawn(["python3", "-m", "http.server", String(port)], {
  cwd: new URL(here).pathname,
  stdout: "ignore",
  stderr: "ignore",
});

const debugPort = 9334;
const chrome = Bun.spawn(
  [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "--headless=new",
    "--no-sandbox",
    `--remote-debugging-port=${debugPort}`,
    `--user-data-dir=/tmp/gosslens-track-${Date.now()}`,
    "about:blank",
  ],
  { stdout: "ignore", stderr: "ignore" },
);

async function devtools(): Promise<string> {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try {
      const targets = (await (await fetch(`http://127.0.0.1:${debugPort}/json`)).json()) as Array<{
        type: string;
        webSocketDebuggerUrl: string;
      }>;
      const page = targets.find((t) => t.type === "page");
      if (page) return page.webSocketDebuggerUrl;
    } catch {}
    await Bun.sleep(250);
  }
  throw new Error("devtools endpoint never came up");
}

const ws = new WebSocket(await devtools());
let nextId = 1;
const pending = new Map<number, (value: unknown) => void>();
ws.addEventListener("message", (event) => {
  const message = JSON.parse(String(event.data));
  if (message.id && pending.has(message.id)) {
    pending.get(message.id)!(message.result);
    pending.delete(message.id);
  }
});
function send(method: string, params: object = {}): Promise<unknown> {
  const id = nextId++;
  ws.send(JSON.stringify({ id, method, params }));
  return new Promise((resolve) => pending.set(id, resolve));
}

await new Promise((resolve) => ws.addEventListener("open", resolve));
await send("Page.enable");
await send("Page.navigate", { url: `http://localhost:${port}/track.html` });

let title = "";
for (let waited = 0; waited < 90_000; waited += 1000) {
  await Bun.sleep(1000);
  const result = (await send("Runtime.evaluate", {
    expression: "document.title",
    returnByValue: true,
  })) as { result?: { value?: string } };
  title = result.result?.value ?? "";
  if (title.startsWith("GOSSTRACK PASS") || title.startsWith("GOSSTRACK FAIL")) break;
}

chrome.kill();
server.kill();
console.log(title || "GOSSTRACK FAIL no proof line");
process.exit(title.startsWith("GOSSTRACK PASS") ? 0 : 1);
