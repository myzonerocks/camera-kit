// The tracking worker: hosts the wasm tracking module so inference never
// blocks the page. The page sends the module and model bundle once, then
// RGBA frames; each processed frame answers with the parsed result. Frames
// arrive as transferred buffers, so the exchange copies nothing on the
// page side.

import { FaceTracker } from "../src/tracking";

FaceTracker.onStage = (stage) => self.postMessage({ kind: "stage", stage });

let tracker: FaceTracker | null = null;

self.postMessage({ kind: "booted" });
self.onerror = (event) => {
  self.postMessage({ kind: "error", message: String(event) });
};

interface InitMessage {
  kind: "init";
  moduleBytes: ArrayBuffer;
  taskBundle: ArrayBuffer;
}

interface FrameMessage {
  kind: "frame";
  rgba: ArrayBuffer;
  width: number;
  height: number;
  timestampUs: number;
}

self.onmessage = async (event: MessageEvent<InitMessage | FrameMessage>) => {
  const message = event.data;
  if (message.kind === "init") {
    try {
      self.postMessage({ kind: "stage", stage: "init received" });
      tracker = await FaceTracker.create(message.moduleBytes, new Uint8Array(message.taskBundle));
      self.postMessage({ kind: "ready" });
    } catch (error) {
      self.postMessage({ kind: "error", message: String(error) });
    }
    return;
  }
  if (message.kind === "frame") {
    if (!tracker) return;
    const result = tracker.process(
      new Uint8Array(message.rgba),
      message.width,
      message.height,
      BigInt(message.timestampUs),
    );
    if (result) {
      self.postMessage({
        kind: "result",
        frameSerial: result.frameSerial.toString(),
        timestampUs: result.timestampUs.toString(),
        presence: result.presence,
        landmarkCount: result.landmarkCount,
        landmarks: result.landmarks,
        blendshapes: result.blendshapes,
      });
    }
  }
};
