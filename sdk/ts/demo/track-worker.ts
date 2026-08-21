// Runs all four web tracking pipelines over the corpus, one at a time, so
// the peak footprint is a single tracker. Each proves in a real browser:
// the module instantiated, the model bundle parsed, inference over a
// decoded still. Reports one structured summary the page turns into a title.

import { FaceTracker, PoseTracker, HandTracker, Segmenter } from "../src/tracking";

interface Frame {
  rgba: Uint8Array;
  width: number;
  height: number;
}

// The corpus stills are full-resolution photos; sampling happens inside
// each pipeline, so a long side of 1024 is ample and keeps the decoded
// buffer small enough to stand four trackers up in sequence comfortably.
async function loadFrame(url: string): Promise<Frame> {
  const blob = await (await fetch(url)).blob();
  const bitmap = await createImageBitmap(blob);
  const scale = Math.min(1, 1024 / Math.max(bitmap.width, bitmap.height));
  const width = Math.max(1, Math.round(bitmap.width * scale));
  const height = Math.max(1, Math.round(bitmap.height * scale));
  const canvas = new OffscreenCanvas(width, height);
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("no 2d context");
  ctx.drawImage(bitmap, 0, 0, width, height);
  bitmap.close();
  const image = ctx.getImageData(0, 0, width, height);
  return { rgba: new Uint8Array(image.data.buffer), width, height };
}

async function bundle(url: string): Promise<Uint8Array> {
  return new Uint8Array(await (await fetch(url)).arrayBuffer());
}

function meanMask(mask: Float32Array): number {
  let sum = 0;
  for (const value of mask) sum += value;
  return sum / mask.length;
}

async function run(): Promise<Record<string, unknown>> {
  const moduleBytes = await (await fetch("./gosslens_tracking.wasm")).arrayBuffer();
  const summary: Record<string, unknown> = {};

  // Face: the corpus portrait detects, the control frame stays empty.
  {
    const tracker = await FaceTracker.create(moduleBytes, await bundle("./face_landmarker.task"));
    const face = await loadFrame("./face_frontal_b.jpg");
    let present = null;
    for (let f = 0; f < 3; f += 1) present = tracker.process(face.rgba, face.width, face.height, BigInt(f * 33_000));
    const control = await loadFrame("./no_face_control.jpg");
    let empty = null;
    for (let f = 0; f < 3; f += 1) empty = tracker.process(control.rgba, control.width, control.height, BigInt((f + 3) * 33_000));
    tracker.destroy();
    summary.face = {
      presentCount: present?.landmarkCount ?? 0,
      presentScore: present?.presence ?? 0,
      controlCount: empty?.landmarkCount ?? 0,
      ok: (present?.landmarkCount ?? 0) > 0 && (empty?.landmarkCount ?? 0) === 0,
    };
  }

  // Pose: the standing body resolves the 33-landmark skeleton.
  {
    const tracker = await PoseTracker.create(moduleBytes, await bundle("./pose_landmarker_full.task"));
    const body = await loadFrame("./body_standing.jpg");
    let pose = null;
    for (let f = 0; f < 4; f += 1) pose = tracker.process(body.rgba, body.width, body.height, BigInt(f * 33_000));
    tracker.destroy();
    summary.pose = {
      landmarkCount: pose?.landmarkCount ?? 0,
      score: pose?.presence ?? 0,
      ok: (pose?.landmarkCount ?? 0) > 0,
    };
  }

  // Hand: the full gesture bundle nests the landmarker, so this proves
  // landmarks, handedness and a canned gesture off one raised hand.
  {
    const tracker = await HandTracker.create(moduleBytes, await bundle("./gesture_recognizer.task"));
    const raised = await loadFrame("./hand_raised.jpg");
    let hand = null;
    for (let f = 0; f < 4; f += 1) hand = tracker.process(raised.rgba, raised.width, raised.height, BigInt(f * 33_000));
    tracker.destroy();
    const first = hand?.hands[0];
    summary.hand = {
      handCount: hand?.handCount ?? 0,
      handedness: first?.handedness ?? 0,
      gesture: first?.gesture ?? -1,
      ok: (hand?.handCount ?? 0) > 0,
    };
  }

  // Segmentation: the multiclass model gives a subject mask plus its own
  // class channels, the ones a lens binds per channel.
  {
    const segmenter = await Segmenter.create(moduleBytes, await bundle("./selfie_multiclass.tflite"));
    const face = await loadFrame("./face_frontal_b.jpg");
    let subject: Float32Array | null = null;
    for (let f = 0; f < 2; f += 1) subject = segmenter.process(face.rgba, face.width, face.height);
    const classCount = segmenter.classCount;
    const hairChannel = segmenter.classMask(1);
    segmenter.destroy();
    const subjectMean = subject ? meanMask(subject) : 0;
    summary.segmentation = {
      classCount,
      subjectMean,
      hairChannel: hairChannel ? meanMask(hairChannel) : null,
      ok: classCount >= 1 && subject !== null && subjectMean > 0.01 && subjectMean < 0.99 && hairChannel !== null,
    };
  }

  return summary;
}

self.addEventListener("message", (event: MessageEvent) => {
  if ((event.data as { kind?: string })?.kind !== "run") return;
  run()
    .then((summary) => self.postMessage({ kind: "done", summary }))
    .catch((error) => self.postMessage({ kind: "error", message: String(error?.stack ?? error) }));
});
