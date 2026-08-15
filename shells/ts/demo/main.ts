import { Core, PreviewSession } from "../src/index.ts";

const status = document.getElementById("status")!;
const canvas = document.getElementById("preview") as HTMLCanvasElement;

let proofLogged = false;

async function run(): Promise<void> {
  const core = await Core.load(new URL("./camerakit.wasm", import.meta.url));
  const version = core.abiVersion();
  status.textContent = `abi ${version >> 16}.${version & 0xffff}`;

  // The conversion matrix comes from the core; sanity-check one known
  // anchor so a broken wasm surface fails loudly here, not in a shader.
  const m = core.yuvToRgbMatrix(1, 0);
  if (Math.abs(m[0] - 255 / 219) > 1e-4) {
    status.textContent = "core color matrix wrong";
    return;
  }

  const engine = core.createEngine();
  const session = core.createSession(engine);

  const preview = new PreviewSession(core, session, canvas, {
    onState(state) {
      status.textContent = `capture ${state}`;
      document.title = `camerakit ${state}`;
    },
    onFps(fps, rendered, cameraFrames) {
      const level = core.degradeLevel(session);
      status.textContent = `capture ${preview.state}  ${fps.toFixed(1)} fps  frames ${cameraFrames}  degrade ${level}`;
      if (!proofLogged && cameraFrames > 30 && fps > 20) {
        const pixel = preview.readCenterPixel();
        const lit = pixel[0] + pixel[1] + pixel[2] > 0;
        if (lit) {
          proofLogged = true;
          const line = `CKWEB preview active: ${cameraFrames} camera frames at ${fps.toFixed(1)} fps, center pixel ${pixel[0]},${pixel[1]},${pixel[2]}`;
          console.log(line);
          document.title = line;
          const div = document.createElement("div");
          div.id = "proof";
          div.textContent = line;
          document.body.appendChild(div);
        }
      }
    },
  });
  await preview.start();
}

run().catch((err) => {
  status.textContent = String(err);
});
