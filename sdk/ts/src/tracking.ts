// The web face tracker: the tracking module compiled to wasm, run inside a
// Worker so inference never touches the main thread. The module speaks
// wasi for its clock and random imports; the tiny shim below covers
// exactly what it reaches for, no filesystem, no sockets. Frames go in as
// RGBA pixels, the frozen result struct comes back parsed.

export const GOSS_FACE_LANDMARK_COUNT = 478;
export const GOSS_FACE_BLENDSHAPE_COUNT = 52;

export interface GossFaceResult {
  frameSerial: bigint;
  timestampUs: bigint;
  presence: number;
  landmarkCount: number;
  /** x, y frame pixels and z, three floats per landmark. */
  landmarks: Float32Array;
  blendshapes: Float32Array;
}

interface TrackingExports {
  memory: WebAssembly.Memory;
  goss_tracking_alloc(size: number): number;
  goss_tracking_free(ptr: number, size: number): void;
  goss_tracking_result_size(): number;
  goss_tracking_create(taskPtr: number, taskLen: number): number;
  goss_tracking_destroy(instance: number): void;
  goss_tracking_process(instance: number, rgba: number, width: number, height: number, timestampUs: bigint): number;
  goss_tracking_result(instance: number, out: number): number;
}

/** The wasi surface the module actually imports: a monotonic clock for
 * profiling counters, randomness for hashing seeds, and exit/write stubs
 * the standard library references but this module never drives. */
function wasiImports(getMemory: () => WebAssembly.Memory): WebAssembly.ModuleImports {
  return {
    clock_time_get: (_clock: number, _precision: bigint, outPtr: number): number => {
      const now = BigInt(Math.round(performance.now() * 1e6));
      new DataView(getMemory().buffer).setBigUint64(outPtr, now, true);
      return 0;
    },
    random_get: (ptr: number, len: number): number => {
      const bytes = new Uint8Array(getMemory().buffer, ptr, len);
      crypto.getRandomValues(bytes);
      return 0;
    },
    fd_write: (fd: number, iovs: number, iovsLen: number, writtenPtr: number): number => {
      // Consume every byte or the writer retries forever; log lines
      // surface on the console where they help.
      const view = new DataView(getMemory().buffer);
      let total = 0;
      let text = "";
      for (let at = 0; at < iovsLen; at += 1) {
        const ptr = view.getUint32(iovs + at * 8, true);
        const len = view.getUint32(iovs + at * 8 + 4, true);
        total += len;
        if (len > 0 && fd <= 2) {
          text += new TextDecoder().decode(new Uint8Array(getMemory().buffer, ptr, Math.min(len, 4096)));
        }
      }
      if (text.trim().length > 0) console.log(`tracking module: ${text.trim()}`);
      view.setUint32(writtenPtr, total, true);
      return 0;
    },
    fd_close: (): number => 0,
    fd_seek: (): number => 0,
    fd_fdstat_get: (): number => 8,
    proc_exit: (code: number): never => {
      throw new Error(`tracking module exited ${code}`);
    },
    environ_sizes_get: (countPtr: number, sizePtr: number): number => {
      const view = new DataView(getMemory().buffer);
      view.setUint32(countPtr, 0, true);
      view.setUint32(sizePtr, 0, true);
      return 0;
    },
    environ_get: (): number => 0,
    args_sizes_get: (countPtr: number, sizePtr: number): number => {
      const view = new DataView(getMemory().buffer);
      view.setUint32(countPtr, 0, true);
      view.setUint32(sizePtr, 0, true);
      return 0;
    },
    args_get: (): number => 0,
  };
}

/// Anything else the module's startup declares but never drives answers
/// with the not-supported code, so instantiation is total without hiding
/// a call that matters.
function totalWasi(getMemory: () => WebAssembly.Memory): WebAssembly.ModuleImports {
  const implemented = wasiImports(getMemory);
  return new Proxy(implemented, {
    get(target, property: string) {
      return target[property] ?? (() => 52);
    },
  });
}

/// Parses the frozen goss_face_result layout out of module memory at ptr:
/// frameSerial u64, timestampUs i64, presence f32, landmarkCount u32, then
/// the landmark and blendshape floats. Pure over the buffer so it is testable
/// without the wasm module.
export function parseFaceResult(buffer: ArrayBuffer, ptr: number): GossFaceResult {
  const view = new DataView(buffer, ptr);
  const floats = new Float32Array(buffer, ptr + 24, GOSS_FACE_LANDMARK_COUNT * 3 + GOSS_FACE_BLENDSHAPE_COUNT);
  return {
    frameSerial: view.getBigUint64(0, true),
    timestampUs: view.getBigInt64(8, true),
    presence: view.getFloat32(16, true),
    landmarkCount: view.getUint32(20, true),
    landmarks: floats.slice(0, GOSS_FACE_LANDMARK_COUNT * 3),
    blendshapes: floats.slice(GOSS_FACE_LANDMARK_COUNT * 3),
  };
}

export class GossFaceTracker {
  private constructor(
    private exports: TrackingExports,
    private instance: number,
    private resultPtr: number,
    private framePtr: number,
    private frameCapacity: number,
  ) {}

  /** Instantiates the module and stands the engines up from the task
   * bundle bytes. Call inside a Worker: creation parses three models and
   * takes real time, and process runs inference synchronously. */
  /** Optional stage reporting for hosts that want startup visibility. */
  static onStage: ((stage: string) => void) | null = null;

  static async create(moduleBytes: ArrayBuffer, taskBundle: Uint8Array): Promise<GossFaceTracker> {
    let memory: WebAssembly.Memory | undefined;
    GossFaceTracker.onStage?.("instantiating");
    const { instance } = await WebAssembly.instantiate(moduleBytes, {
      wasi_snapshot_preview1: totalWasi(() => memory!),
    });
    GossFaceTracker.onStage?.("instantiated");
    const exports = instance.exports as unknown as TrackingExports;
    memory = exports.memory;

    GossFaceTracker.onStage?.("engines starting");
    const taskPtr = exports.goss_tracking_alloc(taskBundle.length);
    if (taskPtr === 0) throw new Error("tracking module allocation failed");
    new Uint8Array(exports.memory.buffer, taskPtr, taskBundle.length).set(taskBundle);
    GossFaceTracker.onStage?.("bundle staged");
    const handle = exports.goss_tracking_create(taskPtr, taskBundle.length);
    GossFaceTracker.onStage?.("engines returned");
    exports.goss_tracking_free(taskPtr, taskBundle.length);
    if (handle === 0) throw new Error("tracking bundle rejected");

    const resultPtr = exports.goss_tracking_alloc(exports.goss_tracking_result_size());
    if (resultPtr === 0) throw new Error("tracking module allocation failed");
    return new GossFaceTracker(exports, handle, resultPtr, 0, 0);
  }

  /** Runs the pipeline over one RGBA frame; returns the parsed result, or
   * null while nothing has been published yet. */
  process(rgba: Uint8Array, width: number, height: number, timestampUs: bigint): GossFaceResult | null {
    const needed = width * height * 4;
    if (rgba.length < needed) throw new Error("frame shorter than its dimensions");
    if (this.frameCapacity < needed) {
      if (this.framePtr !== 0) this.exports.goss_tracking_free(this.framePtr, this.frameCapacity);
      this.framePtr = this.exports.goss_tracking_alloc(needed);
      if (this.framePtr === 0) throw new Error("tracking module allocation failed");
      this.frameCapacity = needed;
    }
    new Uint8Array(this.exports.memory.buffer, this.framePtr, needed).set(rgba.subarray(0, needed));
    if (this.exports.goss_tracking_process(this.instance, this.framePtr, width, height, timestampUs) !== 0) {
      throw new Error("tracking process refused the frame");
    }
    return this.latest();
  }

  /** The newest published result, parsed out of the frozen layout. */
  latest(): GossFaceResult | null {
    if (this.exports.goss_tracking_result(this.instance, this.resultPtr) !== 0) return null;
    return parseFaceResult(this.exports.memory.buffer, this.resultPtr);
  }

  destroy(): void {
    this.exports.goss_tracking_destroy(this.instance);
    if (this.framePtr !== 0) this.exports.goss_tracking_free(this.framePtr, this.frameCapacity);
    this.exports.goss_tracking_free(this.resultPtr, this.exports.goss_tracking_result_size());
  }
}

export const GOSS_SEGMENTATION_MASK_SIDE = 256;

interface SegmentationExports {
  memory: WebAssembly.Memory;
  goss_tracking_alloc(size: number): number;
  goss_tracking_free(ptr: number, size: number): void;
  goss_segmentation_mask_side(): number;
  goss_segmentation_create(modelPtr: number, modelLen: number, threads: number): number;
  goss_segmentation_destroy(core: number): void;
  goss_segmentation_process(core: number, rgba: number, width: number, height: number): number;
  goss_segmentation_read_mask(core: number, out: number): number;
  goss_segmentation_class_count(core: number): number;
  goss_segmentation_read_class_mask(core: number, classIndex: number, out: number): number;
}

/// The web segmenter: the same wasm module's segmentation core, run in a
/// Worker. A single .tflite model in, a mask_side x mask_side subject mask
/// out. Feed the mask to a session with setSegmentationMask.
export class GossSegmenter {
  private constructor(
    private exports: SegmentationExports,
    private core: number,
    private maskPtr: number,
    private maskSide: number,
    private framePtr: number,
    private frameCapacity: number,
  ) {}

  static async create(moduleBytes: ArrayBuffer, modelBytes: Uint8Array): Promise<GossSegmenter> {
    let memory: WebAssembly.Memory | undefined;
    const { instance } = await WebAssembly.instantiate(moduleBytes, {
      wasi_snapshot_preview1: totalWasi(() => memory!),
    });
    const exports = instance.exports as unknown as SegmentationExports;
    memory = exports.memory;

    const modelPtr = exports.goss_tracking_alloc(modelBytes.length);
    if (modelPtr === 0) throw new Error("segmentation module allocation failed");
    new Uint8Array(exports.memory.buffer, modelPtr, modelBytes.length).set(modelBytes);
    const core = exports.goss_segmentation_create(modelPtr, modelBytes.length, 1);
    exports.goss_tracking_free(modelPtr, modelBytes.length);
    if (core === 0) throw new Error("segmentation model rejected");

    const side = exports.goss_segmentation_mask_side();
    const maskPtr = exports.goss_tracking_alloc(side * side * 4);
    if (maskPtr === 0) throw new Error("segmentation module allocation failed");
    return new GossSegmenter(exports, core, maskPtr, side, 0, 0);
  }

  /** Runs the segmenter over one RGBA frame; returns the subject mask
   * (mask_side x mask_side floats), or null before the first result. */
  process(rgba: Uint8Array, width: number, height: number): Float32Array | null {
    const needed = width * height * 4;
    if (rgba.length < needed) throw new Error("frame shorter than its dimensions");
    if (this.frameCapacity < needed) {
      if (this.framePtr !== 0) this.exports.goss_tracking_free(this.framePtr, this.frameCapacity);
      this.framePtr = this.exports.goss_tracking_alloc(needed);
      if (this.framePtr === 0) throw new Error("segmentation module allocation failed");
      this.frameCapacity = needed;
    }
    new Uint8Array(this.exports.memory.buffer, this.framePtr, needed).set(rgba.subarray(0, needed));
    if (this.exports.goss_segmentation_process(this.core, this.framePtr, width, height) !== 0) {
      throw new Error("segmentation process refused the frame");
    }
    if (this.exports.goss_segmentation_read_mask(this.core, this.maskPtr) !== 0) return null;
    const count = this.maskSide * this.maskSide;
    return new Float32Array(this.exports.memory.buffer, this.maskPtr, count).slice(0, count);
  }

  /** How many classes the model publishes: one for the selfie/hair
   * segmenters, more for the multiclass model behind per-class channels. */
  get classCount(): number {
    return this.exports.goss_segmentation_class_count(this.core);
  }

  /** One class channel (mask_side x mask_side floats) from the last
   * processed frame, or null before the first result. classIndex runs the
   * model's own label order; channel N of the mask channels reads N - 1. */
  classMask(classIndex: number): Float32Array | null {
    if (this.exports.goss_segmentation_read_class_mask(this.core, classIndex, this.maskPtr) !== 0) return null;
    const count = this.maskSide * this.maskSide;
    return new Float32Array(this.exports.memory.buffer, this.maskPtr, count).slice(0, count);
  }

  destroy(): void {
    this.exports.goss_segmentation_destroy(this.core);
    if (this.framePtr !== 0) this.exports.goss_tracking_free(this.framePtr, this.frameCapacity);
    this.exports.goss_tracking_free(this.maskPtr, this.maskSide * this.maskSide * 4);
  }
}

export const GOSS_POSE_LANDMARK_COUNT = 33;

export interface GossPoseResult {
  frameSerial: bigint;
  timestampUs: bigint;
  presence: number;
  landmarkCount: number;
  /** x, y frame pixels and z, three floats per landmark. */
  landmarks: Float32Array;
  visibilities: Float32Array;
  presences: Float32Array;
}

interface PoseExports {
  memory: WebAssembly.Memory;
  goss_tracking_alloc(size: number): number;
  goss_tracking_free(ptr: number, size: number): void;
  goss_pose_result_size(): number;
  goss_pose_create(taskPtr: number, taskLen: number): number;
  goss_pose_destroy(instance: number): void;
  goss_pose_process(instance: number, rgba: number, width: number, height: number, timestampUs: bigint): number;
  goss_pose_result(instance: number, out: number): number;
}

/// The web pose tracker: the wasm module's pose pipeline, run in a Worker.
/// A pose task bundle in, the 33-landmark pose result out per frame.
/// Parses the frozen goss_pose_result layout: the header, then the 33-point
/// landmark floats, the visibility scores, and the presence scores. Pure over
/// the buffer so it is testable without the wasm module.
export function parsePoseResult(buffer: ArrayBuffer, ptr: number): GossPoseResult {
  const view = new DataView(buffer, ptr);
  return {
    frameSerial: view.getBigUint64(0, true),
    timestampUs: view.getBigInt64(8, true),
    presence: view.getFloat32(16, true),
    landmarkCount: view.getUint32(20, true),
    landmarks: new Float32Array(buffer, ptr + 24, GOSS_POSE_LANDMARK_COUNT * 3).slice(),
    visibilities: new Float32Array(buffer, ptr + 24 + GOSS_POSE_LANDMARK_COUNT * 3 * 4, GOSS_POSE_LANDMARK_COUNT).slice(),
    presences: new Float32Array(buffer, ptr + 24 + GOSS_POSE_LANDMARK_COUNT * 4 * 4, GOSS_POSE_LANDMARK_COUNT).slice(),
  };
}

export class GossPoseTracker {
  private constructor(
    private exports: PoseExports,
    private instance: number,
    private resultPtr: number,
    private framePtr: number,
    private frameCapacity: number,
  ) {}

  static async create(moduleBytes: ArrayBuffer, taskBundle: Uint8Array): Promise<GossPoseTracker> {
    let memory: WebAssembly.Memory | undefined;
    const { instance } = await WebAssembly.instantiate(moduleBytes, {
      wasi_snapshot_preview1: totalWasi(() => memory!),
    });
    const exports = instance.exports as unknown as PoseExports;
    memory = exports.memory;

    const taskPtr = exports.goss_tracking_alloc(taskBundle.length);
    if (taskPtr === 0) throw new Error("pose module allocation failed");
    new Uint8Array(exports.memory.buffer, taskPtr, taskBundle.length).set(taskBundle);
    const handle = exports.goss_pose_create(taskPtr, taskBundle.length);
    exports.goss_tracking_free(taskPtr, taskBundle.length);
    if (handle === 0) throw new Error("pose bundle rejected");

    const resultPtr = exports.goss_tracking_alloc(exports.goss_pose_result_size());
    if (resultPtr === 0) throw new Error("pose module allocation failed");
    return new GossPoseTracker(exports, handle, resultPtr, 0, 0);
  }

  process(rgba: Uint8Array, width: number, height: number, timestampUs: bigint): GossPoseResult | null {
    const needed = width * height * 4;
    if (rgba.length < needed) throw new Error("frame shorter than its dimensions");
    if (this.frameCapacity < needed) {
      if (this.framePtr !== 0) this.exports.goss_tracking_free(this.framePtr, this.frameCapacity);
      this.framePtr = this.exports.goss_tracking_alloc(needed);
      if (this.framePtr === 0) throw new Error("pose module allocation failed");
      this.frameCapacity = needed;
    }
    new Uint8Array(this.exports.memory.buffer, this.framePtr, needed).set(rgba.subarray(0, needed));
    if (this.exports.goss_pose_process(this.instance, this.framePtr, width, height, timestampUs) !== 0) {
      throw new Error("pose process refused the frame");
    }
    return this.latest();
  }

  latest(): GossPoseResult | null {
    if (this.exports.goss_pose_result(this.instance, this.resultPtr) !== 0) return null;
    return parsePoseResult(this.exports.memory.buffer, this.resultPtr);
  }

  destroy(): void {
    this.exports.goss_pose_destroy(this.instance);
    if (this.framePtr !== 0) this.exports.goss_tracking_free(this.framePtr, this.frameCapacity);
    this.exports.goss_tracking_free(this.resultPtr, this.exports.goss_pose_result_size());
  }
}

export const GOSS_HAND_LANDMARK_COUNT = 21;
export const GOSS_MAX_HANDS = 2;
const HAND_STRIDE = 16 + GOSS_HAND_LANDMARK_COUNT * 3 * 4; // one GossHand, bytes

export interface GossHand {
  presence: number;
  /** the model's score that this is a right hand. */
  handedness: number;
  /** index into the canned gesture set; 0 when none/unavailable. */
  gesture: number;
  gestureScore: number;
  landmarks: Float32Array;
}

export interface GossHandResult {
  frameSerial: bigint;
  timestampUs: bigint;
  handCount: number;
  hands: GossHand[];
}

interface HandExports {
  memory: WebAssembly.Memory;
  goss_tracking_alloc(size: number): number;
  goss_tracking_free(ptr: number, size: number): void;
  goss_hand_result_size(): number;
  goss_hand_create(taskPtr: number, taskLen: number): number;
  goss_hand_destroy(instance: number): void;
  goss_hand_process(instance: number, rgba: number, width: number, height: number, timestampUs: bigint): number;
  goss_hand_result(instance: number, out: number): number;
}

/// The web hand tracker: the wasm module's hand pipeline, run in a Worker.
/// A hand landmarker or gesture-recognizer bundle in, up to two tracked
/// hands out - landmarks, handedness, and a canned gesture when present.
/// Parses the frozen goss_hand_result layout: the header with hand_count at
/// offset 16, then up to GOSS_MAX_HANDS records at offset 24, each a
/// HAND_STRIDE-byte GossHand. Pure over the buffer so it is testable without
/// the wasm module.
export function parseHandResult(buffer: ArrayBuffer, ptr: number): GossHandResult {
  const view = new DataView(buffer, ptr);
  const handCount = view.getUint32(16, true);
  const hands: GossHand[] = [];
  for (let h = 0; h < handCount && h < GOSS_MAX_HANDS; h += 1) {
    const base = 24 + h * HAND_STRIDE;
    hands.push({
      presence: view.getFloat32(base, true),
      handedness: view.getFloat32(base + 4, true),
      gesture: view.getUint32(base + 8, true),
      gestureScore: view.getFloat32(base + 12, true),
      landmarks: new Float32Array(buffer, ptr + base + 16, GOSS_HAND_LANDMARK_COUNT * 3).slice(),
    });
  }
  return {
    frameSerial: view.getBigUint64(0, true),
    timestampUs: view.getBigInt64(8, true),
    handCount,
    hands,
  };
}

export class GossHandTracker {
  private constructor(
    private exports: HandExports,
    private instance: number,
    private resultPtr: number,
    private framePtr: number,
    private frameCapacity: number,
  ) {}

  static async create(moduleBytes: ArrayBuffer, taskBundle: Uint8Array): Promise<GossHandTracker> {
    let memory: WebAssembly.Memory | undefined;
    const { instance } = await WebAssembly.instantiate(moduleBytes, {
      wasi_snapshot_preview1: totalWasi(() => memory!),
    });
    const exports = instance.exports as unknown as HandExports;
    memory = exports.memory;

    const taskPtr = exports.goss_tracking_alloc(taskBundle.length);
    if (taskPtr === 0) throw new Error("hand module allocation failed");
    new Uint8Array(exports.memory.buffer, taskPtr, taskBundle.length).set(taskBundle);
    const handle = exports.goss_hand_create(taskPtr, taskBundle.length);
    exports.goss_tracking_free(taskPtr, taskBundle.length);
    if (handle === 0) throw new Error("hand bundle rejected");

    const resultPtr = exports.goss_tracking_alloc(exports.goss_hand_result_size());
    if (resultPtr === 0) throw new Error("hand module allocation failed");
    return new GossHandTracker(exports, handle, resultPtr, 0, 0);
  }

  process(rgba: Uint8Array, width: number, height: number, timestampUs: bigint): GossHandResult | null {
    const needed = width * height * 4;
    if (rgba.length < needed) throw new Error("frame shorter than its dimensions");
    if (this.frameCapacity < needed) {
      if (this.framePtr !== 0) this.exports.goss_tracking_free(this.framePtr, this.frameCapacity);
      this.framePtr = this.exports.goss_tracking_alloc(needed);
      if (this.framePtr === 0) throw new Error("hand module allocation failed");
      this.frameCapacity = needed;
    }
    new Uint8Array(this.exports.memory.buffer, this.framePtr, needed).set(rgba.subarray(0, needed));
    if (this.exports.goss_hand_process(this.instance, this.framePtr, width, height, timestampUs) !== 0) {
      throw new Error("hand process refused the frame");
    }
    return this.latest();
  }

  latest(): GossHandResult | null {
    if (this.exports.goss_hand_result(this.instance, this.resultPtr) !== 0) return null;
    return parseHandResult(this.exports.memory.buffer, this.resultPtr);
  }

  destroy(): void {
    this.exports.goss_hand_destroy(this.instance);
    if (this.framePtr !== 0) this.exports.goss_tracking_free(this.framePtr, this.frameCapacity);
    this.exports.goss_tracking_free(this.resultPtr, this.exports.goss_hand_result_size());
  }
}
