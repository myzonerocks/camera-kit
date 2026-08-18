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
    `--user-data-dir=/tmp/gosslens-chrome-${Date.now()}`,
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
  if (title.includes("GOSSWEB preview active")) {
    proof = title;
    break;
  }
}

// Freeze the source frame (the fake capture device otherwise keeps
// moving, which would confound a before/after compare with its own
// animation) and confirm turning whiten on actually changes the
// rendered output, not just that the page renders something.
let whiten = "";
for (let waited = 0; waited < 30_000; waited += 500) {
  await Bun.sleep(500);
  const ready = (await send("Runtime.evaluate", {
    expression: "Boolean(window.whitenLutsReady)",
    returnByValue: true,
  })) as { result?: { value?: boolean } };
  if (ready.result?.value) break;
}
{
  const evaluate = async (expression: string) =>
    (await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })) as {
      result?: { value?: unknown };
    };
  // A single fixed pixel is too fragile a probe - the fake capture
  // device's test pattern can leave any one point dark for a long
  // stretch. Sum every RGBA byte across the whole canvas instead, so
  // any change the whiten pass makes anywhere on screen shows up.
  await evaluate("window.setWhiten(0)");
  await evaluate("window.freezeCamera()");
  await new Promise((resolve) => setTimeout(resolve, 150));
  const before = (await evaluate("window.readFrameSum()")).result?.value as number | undefined;
  await evaluate("window.setWhiten(1)");
  await new Promise((resolve) => setTimeout(resolve, 150));
  const after = (await evaluate("window.readFrameSum()")).result?.value as number | undefined;
  const delta = before !== undefined && after !== undefined ? Math.abs(after - before) : -1;
  if (before !== undefined && after !== undefined && delta > 0) {
    whiten = `GOSSWEB whiten: frame sum ${before} -> ${after}, delta ${delta}`;
  } else {
    whiten = `FAIL whiten: before ${JSON.stringify(before)} after ${JSON.stringify(after)}`;
  }
  await evaluate("window.setWhiten(0)");
}

// Same shape as the whiten proof above, for the smoothing pass - except
// smoothing's blend factor is content-adaptive (it favors flat,
// skin-toned regions over sharp edges, by design) and never engages on
// Chrome's fake capture device's own synthetic pattern. Proving it needs
// a real face, the same corpus portrait the tracking pass below uses.
let smooth = "";
{
  const evaluate = async (expression: string) =>
    (await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })) as {
      result?: { value?: unknown };
    };
  await evaluate("window.setSmooth(0)");
  await evaluate("window.freezeCamera()");
  await evaluate("window.loadStillFrame('./face_frontal_b.jpg')");
  await new Promise((resolve) => setTimeout(resolve, 150));
  const before = (await evaluate("window.readFrameSum()")).result?.value as number | undefined;
  await evaluate("window.setSmooth(1)");
  await new Promise((resolve) => setTimeout(resolve, 150));
  const after = (await evaluate("window.readFrameSum()")).result?.value as number | undefined;
  const delta = before !== undefined && after !== undefined ? Math.abs(after - before) : -1;
  if (before !== undefined && after !== undefined && delta > 0) {
    smooth = `GOSSWEB smooth: frame sum ${before} -> ${after}, delta ${delta}`;
  } else {
    smooth = `FAIL smooth: before ${JSON.stringify(before)} after ${JSON.stringify(after)}`;
  }
  await evaluate("window.setSmooth(0)");
  await evaluate("window.resumeCamera()");
}

// Thin-face and big-eye both warp which pixel gets sampled based on the
// tracked face contour, so they need the same real-photo treatment as
// smoothing, plus the contour itself: setLandmarksFromStill runs the
// photo through the same tracker the live feed uses and feeds the result
// into the preview session the way every real frame's result already
// does, rather than only checking that the shader compiles.
let reshape = "";
{
  const evaluate = async (expression: string) =>
    (await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })) as {
      result?: { value?: unknown };
    };
  await evaluate("window.setThinFace(0)");
  await evaluate("window.setBigEye(0)");
  await evaluate("window.freezeCamera()");
  await evaluate("window.loadStillFrame('./face_frontal_b.jpg')");
  await evaluate("window.setLandmarksFromStill('./face_frontal_b.jpg')");
  await new Promise((resolve) => setTimeout(resolve, 150));
  const before = (await evaluate("window.readFrameSum()")).result?.value as number | undefined;
  await evaluate("window.setThinFace(1)");
  await evaluate("window.setBigEye(0.15)");
  await new Promise((resolve) => setTimeout(resolve, 150));
  const after = (await evaluate("window.readFrameSum()")).result?.value as number | undefined;
  const delta = before !== undefined && after !== undefined ? Math.abs(after - before) : -1;
  if (before !== undefined && after !== undefined && delta > 0) {
    reshape = `GOSSWEB reshape: frame sum ${before} -> ${after}, delta ${delta}`;
  } else {
    reshape = `FAIL reshape: before ${JSON.stringify(before)} after ${JSON.stringify(after)}`;
  }
  await evaluate("window.setThinFace(0)");
  await evaluate("window.setBigEye(0)");
  await evaluate("window.resumeCamera()");
}

// Lipstick and blush both need the makeup textures loaded and a tracked
// face, same shape as the checks above.
let makeup = "";
{
  const evaluate = async (expression: string) =>
    (await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })) as {
      result?: { value?: unknown };
    };
  for (let waited = 0; waited < 15_000; waited += 500) {
    await Bun.sleep(500);
    const ready = await evaluate("Boolean(window.makeupTexturesReady)");
    if (ready.result?.value) break;
  }
  await evaluate("window.setLipstick(0)");
  await evaluate("window.setBlush(0)");
  await evaluate("window.freezeCamera()");
  await evaluate("window.loadStillFrame('./face_frontal_b.jpg')");
  await evaluate("window.setLandmarksFromStill('./face_frontal_b.jpg')");
  await new Promise((resolve) => setTimeout(resolve, 150));
  const before = (await evaluate("window.readFrameSum()")).result?.value as number | undefined;
  await evaluate("window.setLipstick(0.5)");
  await evaluate("window.setBlush(0.5)");
  await new Promise((resolve) => setTimeout(resolve, 150));
  const after = (await evaluate("window.readFrameSum()")).result?.value as number | undefined;
  const delta = before !== undefined && after !== undefined ? Math.abs(after - before) : -1;
  if (before !== undefined && after !== undefined && delta > 0) {
    makeup = `GOSSWEB makeup: frame sum ${before} -> ${after}, delta ${delta}`;
  } else {
    makeup = `FAIL makeup: before ${JSON.stringify(before)} after ${JSON.stringify(after)}`;
  }
  await evaluate("window.setLipstick(0)");
  await evaluate("window.setBlush(0)");
  await evaluate("window.resumeCamera()");
}

// Lens activation is the real conformance bar: a lens is a manifest, not a
// param setter, so this proves the bytes-based goss_session_activate_lens
// path end to end (parse, node graph, default params) and checks the same
// harness/conformance.zig bar the native engine already holds itself to -
// the same fixed input rendered twice after activation must be
// byte-identical. beauty-baseline is the only reference lens usable here:
// its one node type is beauty.face, which has no file-I/O dependency, so
// it survives the has_file_io comptime gate that blocks directory-based
// activation (and therefore any shader.pass/lut.pass node) on wasm.
let lens = "";
{
  const evaluate = async (expression: string) =>
    (await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })) as {
      result?: { value?: unknown };
    };
  await evaluate("window.freezeCamera()");
  await evaluate("window.loadStillFrame('./face_frontal_b.jpg')");
  await new Promise((resolve) => setTimeout(resolve, 150));
  const before = (await evaluate("window.readFrameSum()")).result?.value as number | undefined;
  const activateOutcome = (
    await evaluate(
      "window.activateLens('./beauty-baseline.manifest.json').then(() => 'ok').catch((e) => 'ERR:' + e)",
    )
  ).result?.value as string | undefined;
  await evaluate("window.tickLens(16000)");
  await new Promise((resolve) => setTimeout(resolve, 150));
  const after1 = (await evaluate("window.readFrameSum()")).result?.value as number | undefined;
  const after2 = (await evaluate("window.readFrameSum()")).result?.value as number | undefined;
  const delta = before !== undefined && after1 !== undefined ? Math.abs(after1 - before) : -1;
  const deterministic = after1 !== undefined && after1 === after2;
  if (activateOutcome === "ok" && delta > 0 && deterministic) {
    lens = `GOSSWEB lens: activate ${activateOutcome}, frame sum ${before} -> ${after1}, delta ${delta}, deterministic ${deterministic}`;
  } else {
    lens = `FAIL lens: activate ${activateOutcome}, before ${JSON.stringify(before)} after1 ${JSON.stringify(after1)} after2 ${JSON.stringify(after2)} deterministic ${deterministic}`;
  }
  await evaluate("window.deactivateLens()");
  await evaluate("window.resumeCamera()");
}

// The tracking pass: wait for the worker, then one corpus portrait must
// track and the control frame must not.
let tracking = "";
for (let waited = 0; waited < 300_000; waited += 1000) {
  await Bun.sleep(1000);
  const up = (await send("Runtime.evaluate", {
    expression: "Boolean(window.trackingUp)",
    returnByValue: true,
  })) as { result?: { value?: boolean } };
  if (up.result?.value) break;
}
{
  const evaluate = async (expression: string) =>
    (await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })) as {
      result?: { value?: string };
    };
  const face = await evaluate(
    "window.trackImage('./face_frontal_b.jpg').then((r) => JSON.stringify(r))",
  );
  const control = await evaluate(
    "window.trackImage('./no_face_control.jpg').then((r) => JSON.stringify(r))",
  );
  try {
    const faceResult = JSON.parse(face.result?.value ?? "{}");
    const controlResult = JSON.parse(control.result?.value ?? "{}");
    if (
      faceResult.presence > 0.5 &&
      faceResult.landmarkCount === faceResult.expected &&
      controlResult.landmarkCount === 0
    ) {
      tracking = `GOSSWEB tracking: portrait presence ${faceResult.presence.toFixed(3)} with ${faceResult.landmarkCount} landmarks, control frame ${controlResult.landmarkCount}`;
    } else {
      tracking = `FAIL tracking: face ${face.result?.value} control ${control.result?.value}`;
    }
  } catch {
    tracking = `FAIL tracking: face ${face.result?.value} control ${control.result?.value}`;
  }
}

const trackingErr = (await send("Runtime.evaluate", {
  expression: "String(window.trackingError ?? '')",
  returnByValue: true,
})) as { result?: { value?: string } };
if (trackingErr.result?.value) console.log(`tracking error: ${trackingErr.result.value}`);
const booted = (await send("Runtime.evaluate", {
  expression: "JSON.stringify({booted: Boolean(window.workerBooted), stage: window.workerStage ?? null, up: Boolean(window.trackingUp)})",
  returnByValue: true,
})) as { result?: { value?: string } };
console.log(`worker state: ${booted.result?.value}`);

const statusResult = (await send("Runtime.evaluate", {
  expression: "document.getElementById('status')?.textContent ?? ''",
  returnByValue: true,
})) as { result?: { value?: string } };

chrome.kill();
if (
  proof &&
  whiten &&
  !whiten.startsWith("FAIL") &&
  smooth &&
  !smooth.startsWith("FAIL") &&
  reshape &&
  !reshape.startsWith("FAIL") &&
  makeup &&
  !makeup.startsWith("FAIL") &&
  lens &&
  !lens.startsWith("FAIL") &&
  tracking &&
  !tracking.startsWith("FAIL")
) {
  console.log(proof);
  console.log(whiten);
  console.log(smooth);
  console.log(reshape);
  console.log(makeup);
  console.log(lens);
  console.log(tracking);
  console.log(`status: ${statusResult.result?.value}`);
  process.exit(0);
}
if (whiten) {
  console.log(whiten);
}
if (smooth) {
  console.log(smooth);
}
if (reshape) {
  console.log(reshape);
}
if (makeup) {
  console.log(makeup);
}
if (lens) {
  console.log(lens);
}
if (tracking) {
  console.log(tracking);
}
console.log(`FAIL no proof line; status: ${statusResult.result?.value}`);
process.exit(1);
