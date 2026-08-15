// Drives the demo in headless Chrome over the DevTools protocol and prints
// the in-page proof line. Chrome's fake capture device feeds getUserMedia,
// so the whole ingress and render path runs exactly as it does live.

const port = 9333;
const pageUrl = process.argv[2] ?? "http://localhost:8932/index.html";
const chrome = Bun.spawn(
  [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "--headless=new",
    "--no-sandbox",
    `--remote-debugging-port=${port}`,
    "--use-fake-ui-for-media-stream",
    "--use-fake-device-for-media-stream",
    "--autoplay-policy=no-user-gesture-required",
    `--user-data-dir=/tmp/camerakit-chrome-${Date.now()}`,
    "about:blank",
  ],
  { stdout: "ignore", stderr: "ignore" },
);

async function devtools(): Promise<string> {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try {
      const targets = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()) as Array<{
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
await send("Page.navigate", { url: pageUrl });

let proof = "";
for (let waited = 0; waited < 30_000; waited += 1000) {
  await Bun.sleep(1000);
  const result = (await send("Runtime.evaluate", {
    expression: "document.title",
    returnByValue: true,
  })) as { result?: { value?: string } };
  const title = result.result?.value ?? "";
  if (title.includes("CKWEB preview active")) {
    proof = title;
    break;
  }
}

const statusResult = (await send("Runtime.evaluate", {
  expression: "document.getElementById('status')?.textContent ?? ''",
  returnByValue: true,
})) as { result?: { value?: string } };

chrome.kill();
if (proof) {
  console.log(proof);
  console.log(`status: ${statusResult.result?.value}`);
  process.exit(0);
}
console.log(`FAIL no proof line; status: ${statusResult.result?.value}`);
process.exit(1);
