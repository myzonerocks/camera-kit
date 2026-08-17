import { PreviewSession } from "../src/index.ts";
import { FACE_LANDMARK_COUNT } from "../src/tracking.ts";

const status = document.getElementById("status")!;
const canvas = document.getElementById("preview") as HTMLCanvasElement;
const overlay = document.getElementById("overlay") as HTMLCanvasElement;

let proofLogged = false;

interface TrackingReply {
  kind: string;
  message?: string;
  presence: number;
  landmarkCount: number;
  landmarks: Float32Array;
}

/// The tracking worker hosts the wasm module; frames go over as
/// transferred buffers and results come back parsed. Replies arrive in
/// send order, so a queue of resolvers pairs them up.
class TrackerLink {
  private worker: Worker;
  private resolvers: Array<(reply: TrackingReply) => void> = [];
  busy = false;

  private constructor(worker: Worker) {
    this.worker = worker;
    worker.onmessage = (event: MessageEvent<TrackingReply>) => {
      if (event.data.kind !== "result") return;
      this.busy = false;
      this.resolvers.shift()?.(event.data);
    };
  }

  static async create(): Promise<TrackerLink> {
    const [moduleBytes, taskBundle] = await Promise.all([
      fetch(new URL("./camerakit_tracking.wasm", import.meta.url)).then((r) => r.arrayBuffer()),
      fetch(new URL("./face_landmarker.task", import.meta.url)).then((r) => r.arrayBuffer()),
    ]);
    const worker = new Worker(new URL("./tracking-worker.js", import.meta.url), { type: "module" });
    await new Promise<void>((resolve, reject) => {
      worker.onerror = (event) => reject(new Error(`worker: ${event.message}`));
      worker.onmessage = (event: MessageEvent<{ kind: string; message?: string }>) => {
        if (event.data.kind === "booted") {
          (window as unknown as Record<string, unknown>).workerBooted = true;
          return;
        }
        if (event.data.kind === "stage") {
          (window as unknown as Record<string, unknown>).workerStage = (event.data as { stage?: string }).stage;
          return;
        }
        if (event.data.kind === "ready") resolve();
        else reject(new Error(event.data.message ?? "tracking worker failed"));
      };
      worker.postMessage({ kind: "init", moduleBytes, taskBundle }, [moduleBytes, taskBundle]);
    });
    return new TrackerLink(worker);
  }

  send(rgba: Uint8ClampedArray, width: number, height: number, timestampUs: number): Promise<TrackingReply> {
    this.busy = true;
    const copy = new Uint8Array(rgba).buffer;
    return new Promise((resolve) => {
      this.resolvers.push(resolve);
      this.worker.postMessage({ kind: "frame", rgba: copy, width, height, timestampUs }, [copy]);
    });
  }
}

/// Landmarks come back in frame pixels; the overlay scales them into its
/// own square and paints one dot each.
function drawOverlay(reply: TrackingReply, frameWidth: number, frameHeight: number): void {
  const ctx = overlay.getContext("2d")!;
  ctx.clearRect(0, 0, overlay.width, overlay.height);
  if (reply.landmarkCount === 0 || reply.presence < 0.5) return;
  const scaleX = overlay.width / frameWidth;
  const scaleY = overlay.height / frameHeight;
  ctx.fillStyle = "#fff";
  for (let index = 0; index < reply.landmarkCount; index += 1) {
    const x = reply.landmarks[index * 3] * scaleX;
    const y = reply.landmarks[index * 3 + 1] * scaleY;
    ctx.fillRect(x - 1, y - 1, 2, 2);
  }
}

async function startTracking(preview: PreviewSession): Promise<void> {
  const link = await TrackerLink.create();
  const scratch = document.createElement("canvas");
  const ctx = scratch.getContext("2d", { willReadFrequently: true })!;
  let trackingAnnounced = false;

  // One analysis frame in flight at a time, always the newest; the live
  // loop samples the camera element at analysis size.
  const analysisWidth = 480;
  const feed = () => {
    requestAnimationFrame(feed);
    if (link.busy) return;
    const video = preview.video;
    if (video.readyState < 2 || video.videoWidth === 0 || video.paused) return;
    const analysisHeight = Math.round((analysisWidth * video.videoHeight) / video.videoWidth);
    scratch.width = analysisWidth;
    scratch.height = analysisHeight;
    if (preview.isVideoFlipped()) {
      ctx.setTransform(1, 0, 0, -1, 0, analysisHeight);
      ctx.drawImage(video, 0, 0, analysisWidth, analysisHeight);
      ctx.setTransform(1, 0, 0, 1, 0, 0);
    } else {
      ctx.drawImage(video, 0, 0, analysisWidth, analysisHeight);
    }
    const pixels = ctx.getImageData(0, 0, analysisWidth, analysisHeight);
    void link.send(pixels.data, analysisWidth, analysisHeight, Math.round(performance.now() * 1000)).then((reply) => {
      drawOverlay(reply, analysisWidth, analysisHeight);
      preview.setFaceLandmarks(
        reply.presence >= 0.5 && reply.landmarkCount > 0 ? reply.landmarks : null,
        analysisWidth,
        analysisHeight,
      );
      if (!trackingAnnounced) {
        trackingAnnounced = true;
        console.log(`CKWEB tracking running: serial results flowing, presence ${reply.presence.toFixed(3)}`);
      }
    });
  };
  requestAnimationFrame(feed);

  // The still-image path the prover drives: one fetched image through the
  // same worker, resolved with the parsed result.
  (window as unknown as Record<string, unknown>).trackImage = async (url: string) => {
    const bitmap = await createImageBitmap(await (await fetch(url)).blob());
    const still = document.createElement("canvas");
    still.width = bitmap.width;
    still.height = bitmap.height;
    const stillCtx = still.getContext("2d", { willReadFrequently: true })!;
    stillCtx.drawImage(bitmap, 0, 0);
    const pixels = stillCtx.getImageData(0, 0, still.width, still.height);
    const reply = await link.send(pixels.data, still.width, still.height, 0);
    return {
      presence: reply.presence,
      landmarkCount: reply.landmarkCount,
      expected: FACE_LANDMARK_COUNT,
    };
  };
  // Same still-image path, but for reshape's own proof: tracks the image
  // and feeds the result straight into the preview session's face
  // contour, the way the live feed loop above does every frame.
  (window as unknown as Record<string, unknown>).setLandmarksFromStill = async (url: string) => {
    const bitmap = await createImageBitmap(await (await fetch(url)).blob());
    const still = document.createElement("canvas");
    still.width = bitmap.width;
    still.height = bitmap.height;
    const stillCtx = still.getContext("2d", { willReadFrequently: true })!;
    stillCtx.drawImage(bitmap, 0, 0);
    const pixels = stillCtx.getImageData(0, 0, still.width, still.height);
    const reply = await link.send(pixels.data, still.width, still.height, 0);
    preview.setFaceLandmarks(
      reply.presence >= 0.5 && reply.landmarkCount > 0 ? reply.landmarks : null,
      still.width,
      still.height,
    );
  };
  (window as unknown as Record<string, unknown>).trackingUp = true;
}

async function run(): Promise<void> {
  const preview = await PreviewSession.create(canvas, new URL("./camerakit_web.js", import.meta.url), {
    onState(state) {
      status.textContent = `capture ${state}`;
      document.title = `camerakit ${state}`;
    },
    onFps(fps, rendered, cameraFrames) {
      const level = preview.degradeLevel();
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
  // Persisted across reloads: a camera that hands the browser
  // pre-rotated frames does so every time, not just this once. Default
  // true on a device that's never recorded a choice - this demo's own
  // camera does this consistently, so "never asked" should mean
  // "already correct," not "upside down until you notice and fix it."
  const flipCameraCheckbox = document.getElementById("flip-camera") as HTMLInputElement | null;
  const flipRaw = localStorage.getItem("ckweb-flip-camera");
  const flipStored = flipRaw === null ? true : flipRaw === "1";
  if (flipCameraCheckbox) {
    flipCameraCheckbox.checked = flipStored;
    preview.setVideoFlip(flipStored);
    flipCameraCheckbox.addEventListener("change", () => {
      preview.setVideoFlip(flipCameraCheckbox.checked);
      localStorage.setItem("ckweb-flip-camera", flipCameraCheckbox.checked ? "1" : "0");
    });
  }
  startTracking(preview).catch((err) => {
    (window as unknown as Record<string, unknown>).trackingError = String(err);
    console.log(`tracking unavailable: ${String(err)}`);
  });

  await preview.loadWhitenLuts(new URL("./res/", import.meta.url));
  const whitenSlider = document.getElementById("whiten") as HTMLInputElement | null;
  whitenSlider?.addEventListener("input", () => {
    preview.setWhiten(Number(whitenSlider.value));
  });
  (window as unknown as Record<string, unknown>).setWhiten = (value: number) => {
    preview.setWhiten(value);
  };
  const smoothSlider = document.getElementById("smooth") as HTMLInputElement | null;
  smoothSlider?.addEventListener("input", () => {
    preview.setSmooth(Number(smoothSlider.value));
  });
  (window as unknown as Record<string, unknown>).setSmooth = (value: number) => {
    preview.setSmooth(value);
  };
  const thinFaceSlider = document.getElementById("thin-face") as HTMLInputElement | null;
  thinFaceSlider?.addEventListener("input", () => {
    preview.setThinFace(Number(thinFaceSlider.value));
  });
  (window as unknown as Record<string, unknown>).setThinFace = (value: number) => {
    preview.setThinFace(value);
  };
  const bigEyeSlider = document.getElementById("big-eye") as HTMLInputElement | null;
  bigEyeSlider?.addEventListener("input", () => {
    preview.setBigEye(Number(bigEyeSlider.value));
  });
  (window as unknown as Record<string, unknown>).setBigEye = (value: number) => {
    preview.setBigEye(value);
  };
  await preview.loadMakeupTextures(new URL("./res/", import.meta.url));
  const lipstickSlider = document.getElementById("lipstick") as HTMLInputElement | null;
  lipstickSlider?.addEventListener("input", () => {
    preview.setLipstick(Number(lipstickSlider.value));
  });
  (window as unknown as Record<string, unknown>).setLipstick = (value: number) => {
    preview.setLipstick(value);
  };
  const blushSlider = document.getElementById("blush") as HTMLInputElement | null;
  blushSlider?.addEventListener("input", () => {
    preview.setBlush(Number(blushSlider.value));
  });
  (window as unknown as Record<string, unknown>).setBlush = (value: number) => {
    preview.setBlush(value);
  };
  (window as unknown as Record<string, unknown>).makeupTexturesReady = true;
  (window as unknown as Record<string, unknown>).loadStillFrame = (url: string) => preview.loadStillFrame(url);
  (window as unknown as Record<string, unknown>).readCenterPixel = () => Array.from(preview.readCenterPixel());
  (window as unknown as Record<string, unknown>).readFrameSum = () => preview.readFrameSum();
  (window as unknown as Record<string, unknown>).captureFrame = () => preview.captureFrame();
  // Pausing the video element stops the per-frame texture re-upload,
  // freezing whatever the shader is currently sampling.
  (window as unknown as Record<string, unknown>).freezeCamera = () => preview.video.pause();
  (window as unknown as Record<string, unknown>).resumeCamera = () => preview.video.play();
  (window as unknown as Record<string, unknown>).whitenLutsReady = true;
}

run().catch((err) => {
  status.textContent = String(err);
});
