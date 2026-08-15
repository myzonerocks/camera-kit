// The web face tracker: the tracking module compiled to wasm, run inside a
// Worker so inference never touches the main thread. The module speaks
// wasi for its clock and random imports; the tiny shim below covers
// exactly what it reaches for, no filesystem, no sockets. Frames go in as
// RGBA pixels, the frozen result struct comes back parsed.

export const FACE_LANDMARK_COUNT = 478;
export const FACE_BLENDSHAPE_COUNT = 52;

export interface FaceResult {
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
  ck_tracking_alloc(size: number): number;
  ck_tracking_free(ptr: number, size: number): void;
  ck_tracking_result_size(): number;
  ck_tracking_create(taskPtr: number, taskLen: number): number;
  ck_tracking_destroy(instance: number): void;
  ck_tracking_process(instance: number, rgba: number, width: number, height: number, timestampUs: bigint): number;
  ck_tracking_result(instance: number, out: number): number;
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
    fd_write: (_fd: number, _iovs: number, _iovsLen: number, writtenPtr: number): number => {
      new DataView(getMemory().buffer).setUint32(writtenPtr, 0, true);
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
  };
}

export class FaceTracker {
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
  static async create(moduleBytes: ArrayBuffer, taskBundle: Uint8Array): Promise<FaceTracker> {
    let memory: WebAssembly.Memory | undefined;
    const { instance } = await WebAssembly.instantiate(moduleBytes, {
      wasi_snapshot_preview1: wasiImports(() => memory!),
    });
    const exports = instance.exports as unknown as TrackingExports;
    memory = exports.memory;

    const taskPtr = exports.ck_tracking_alloc(taskBundle.length);
    if (taskPtr === 0) throw new Error("tracking module allocation failed");
    new Uint8Array(exports.memory.buffer, taskPtr, taskBundle.length).set(taskBundle);
    const handle = exports.ck_tracking_create(taskPtr, taskBundle.length);
    exports.ck_tracking_free(taskPtr, taskBundle.length);
    if (handle === 0) throw new Error("tracking bundle rejected");

    const resultPtr = exports.ck_tracking_alloc(exports.ck_tracking_result_size());
    if (resultPtr === 0) throw new Error("tracking module allocation failed");
    return new FaceTracker(exports, handle, resultPtr, 0, 0);
  }

  /** Runs the pipeline over one RGBA frame; returns the parsed result, or
   * null while nothing has been published yet. */
  process(rgba: Uint8Array, width: number, height: number, timestampUs: bigint): FaceResult | null {
    const needed = width * height * 4;
    if (rgba.length < needed) throw new Error("frame shorter than its dimensions");
    if (this.frameCapacity < needed) {
      if (this.framePtr !== 0) this.exports.ck_tracking_free(this.framePtr, this.frameCapacity);
      this.framePtr = this.exports.ck_tracking_alloc(needed);
      if (this.framePtr === 0) throw new Error("tracking module allocation failed");
      this.frameCapacity = needed;
    }
    new Uint8Array(this.exports.memory.buffer, this.framePtr, needed).set(rgba.subarray(0, needed));
    if (this.exports.ck_tracking_process(this.instance, this.framePtr, width, height, timestampUs) !== 0) {
      throw new Error("tracking process refused the frame");
    }
    return this.latest();
  }

  /** The newest published result, parsed out of the frozen layout. */
  latest(): FaceResult | null {
    if (this.exports.ck_tracking_result(this.instance, this.resultPtr) !== 0) return null;
    const view = new DataView(this.exports.memory.buffer, this.resultPtr);
    const floats = new Float32Array(this.exports.memory.buffer, this.resultPtr + 24, FACE_LANDMARK_COUNT * 3 + FACE_BLENDSHAPE_COUNT);
    return {
      frameSerial: view.getBigUint64(0, true),
      timestampUs: view.getBigInt64(8, true),
      presence: view.getFloat32(16, true),
      landmarkCount: view.getUint32(20, true),
      landmarks: floats.slice(0, FACE_LANDMARK_COUNT * 3),
      blendshapes: floats.slice(FACE_LANDMARK_COUNT * 3),
    };
  }

  destroy(): void {
    this.exports.ck_tracking_destroy(this.instance);
    if (this.framePtr !== 0) this.exports.ck_tracking_free(this.framePtr, this.frameCapacity);
    this.exports.ck_tracking_free(this.resultPtr, this.exports.ck_tracking_result_size());
  }
}
