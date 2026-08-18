// The web shell over gosslens_web, the real bgfx-backed engine every
// other shell already runs (Swift/Kotlin call the exact same frozen ABI
// through their own thin platform glue). This shell owns only what the
// browser forces on it - camera capture through getUserMedia, decoding
// PNGs the core has no decoder for, driving the render loop - and hands
// everything else (the frame graph, all six beauty effects, mirror and
// rotation) straight to the engine.

export const GOSS_OK = 0;

export const enum DegradeLevel {
  Full = 0,
  ReducedMlCadence = 1,
  SegmentationOff = 2,
  BeautySimplified = 3,
  Passthrough = 4,
}

export const enum BeautyEffect {
  Smooth = 0,
  Whiten = 1,
  ThinFace = 2,
  BigEye = 3,
  Lipstick = 4,
  Blush = 5,
}

const FRAME_FLAG_MIRROR = 0x1;
const FRAME_ROTATION_SHIFT = 8;
const PIXEL_FORMAT_RGBA8 = 4;
export const FACE_LANDMARK_COUNT = 478;

export type CaptureState = "idle" | "running" | "denied" | "failed" | "interrupted";

export interface SessionEvents {
  onState?(state: CaptureState): void;
  onFps?(fps: number, renderedFrames: number, cameraFrames: number): void;
}

/// Emscripten's own Module surface, the pieces this shell actually uses.
/// EXPORTED_RUNTIME_METHODS in build.zig's wasm-emscripten link step is
/// the source of truth for what's actually present at runtime.
interface EngineModule {
  HEAPU8: Uint8Array;
  HEAPF32: Float32Array;
  ccall(name: string, returnType: string | null, argTypes: string[], args: unknown[]): number;
  ccall(name: string, returnType: string | null, argTypes: string[], args: unknown[], opts: { async: true }): Promise<number>;
  getValue(ptr: number, type: string): number;
  setValue(ptr: number, value: number, type: string): void;
  stringToNewUTF8(value: string): number;
}

type EngineModuleFactory = (overrides?: Record<string, unknown>) => Promise<EngineModule>;

/// Decodes a fetched blob to raw RGBA bytes via a 2D canvas. Unlike
/// texImage2D (see the git history on this file - a real, hard-won
/// lesson from the old hand-rolled WebGL2 shell this one replaces),
/// getImageData has always had simple, browser-consistent semantics:
/// row 0 is the visual top of the image, full stop. No DOM-source
/// orientation quirks to work around, because there's no texImage2D
/// involved at all - just plain bytes handed to the engine's own
/// texture upload, which owns its own orientation convention entirely
/// separately from WebGL's.
/// fit, when given, downscales (never upscales) so the decoded frame
/// fits within maxWidth/maxHeight - LUT and makeup textures pass
/// nothing and decode at native resolution; loadStillFrame passes the
/// canvas's own size, since a corpus photo can be far larger than a
/// real camera frame ever would be. The composite chain sizes every
/// offscreen target and the final swap-chain view rect off the
/// submitted frame's own dimensions, so a frame wider or taller than
/// the actual WebGL drawing buffer gets silently clipped by the GPU to
/// whatever corner overlaps it - real, found via a still photo (2400x
/// 3000) submitted straight through to a 1280x720 canvas, where only
/// the top-left ~13% ended up visible and every landmark-driven effect
/// (thin-face, big-eye, lipstick, blush) happened to warp a region
/// entirely outside that sliver, reading back as no change at all.
async function decodeImageRgba(
  blob: Blob,
  fit?: { maxWidth: number; maxHeight: number },
): Promise<{ data: Uint8ClampedArray; width: number; height: number }> {
  const bitmap = await createImageBitmap(blob);
  const scale = fit ? Math.min(1, fit.maxWidth / bitmap.width, fit.maxHeight / bitmap.height) : 1;
  const width = Math.round(bitmap.width * scale);
  const height = Math.round(bitmap.height * scale);
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d")!;
  ctx.drawImage(bitmap, 0, 0, width, height);
  const image = ctx.getImageData(0, 0, width, height);
  return { data: image.data, width, height };
}

/// Chooses which gosslens_web.js build to load: the WebGPU one (bgfx's
/// WebGPU backend, Asyncify linked in) or the WebGL2 one (no Asyncify).
/// Two separate artifacts rather than a runtime toggle, since Asyncify
/// taxes the whole per-frame path, not just init. Checks for a real
/// working adapter, not just navigator.gpu's presence, which can exist
/// with no adapter behind it.
export async function pickEngineUrl(webgpuUrl: string | URL, webgl2Url: string | URL): Promise<string | URL> {
  const gpu = (navigator as unknown as { gpu?: { requestAdapter(): Promise<unknown> } }).gpu;
  if (!gpu) return webgl2Url;
  try {
    const adapter = await gpu.requestAdapter();
    return adapter ? webgpuUrl : webgl2Url;
  } catch {
    return webgl2Url;
  }
}

/// ABI bootstrap: the loaded wasm module plus the two free functions,
/// the same role Kotlin's Gosslens object plays around
/// System.loadLibrary. Module load needs a canvas here, unlike
/// Swift/Kotlin - a real platform difference, not an inconsistency.
export class Gosslens {
  private constructor(
    private readonly mod: EngineModule,
    readonly abiVersion: number,
  ) {}

  /// Loads gosslens_web.js and checks its ABI major version. A
  /// dynamic import, not static: bun's bundler would otherwise inline
  /// this file, breaking Emscripten's own import.meta.url-relative
  /// fetch of gosslens_web.wasm sitting next to it.
  static async load(canvas: HTMLCanvasElement, wasmJsUrl: string | URL): Promise<Gosslens> {
    const imported = (await import(/* @vite-ignore */ String(wasmJsUrl))) as { default: EngineModuleFactory };
    const mod = await imported.default({ canvas });
    const version = mod.ccall("goss_abi_version", "number", [], []) >>> 0;
    if (version >> 16 !== 0) throw new Error(`gosslens abi major mismatch: ${version >> 16}`);
    return new Gosslens(mod, version);
  }

  /// The YCbCr to RGB conversion for a standard and range as one
  /// column-major homogeneous matrix. Unused today (canvas always
  /// yields RGBA already) - a real gap for any future debug/thumbnail
  /// path, kept wrapped so that path doesn't start from a raw ccall.
  yuvToRgb(standard: number, range: number): Float32Array {
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [64]);
    this.mod.ccall("goss_color_yuv_to_rgb", "number", ["number", "number", "number"], [standard, range, ptr]);
    const out = new Float32Array(16);
    for (let i = 0; i < 16; i += 1) out[i] = this.mod.getValue(ptr + i * 4, "float");
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, 64]);
    return out;
  }

  /// @internal - Engine/Session need the raw module to reach the ABI;
  /// nothing outside this file should call ccall directly.
  get module(): EngineModule {
    return this.mod;
  }
}

/// Render-surface lifecycle: create/resize/render/read back. Confined
/// to the one canvas it was created against, matching Session/Engine's
/// single-thread confinement on every other shell.
export class Engine {
  private captureInFlight = false;

  private constructor(
    private readonly mod: EngineModule,
    readonly handle: number,
    private readonly canvas: HTMLCanvasElement,
    /// Only set on the WebGL2 build - bgfx's WebGPU backend binds the
    /// canvas to a 'webgpu' context instead, and a canvas can only ever
    /// bind one context type for its lifetime. capturePixels() branches
    /// on this: readPixels when set, goss_engine_capture_frame otherwise.
    private readonly gl: WebGL2RenderingContext | null,
  ) {}

  /// Stands the engine and its renderer up against canvas, which needs
  /// a stable id: bgfx's own HTML5 backend resolves it via a #id
  /// selector string (glcontext_html5.cpp), separate from the
  /// Module.canvas binding Gosslens.load already made - both must agree.
  static async create(gosslens: Gosslens, canvas: HTMLCanvasElement): Promise<Engine> {
    if (!canvas.id) throw new Error("canvas needs a stable id for bgfx's own selector lookup");
    const mod = gosslens.module;

    const engineOut = mod.ccall("goss_alloc", "number", ["number"], [4]);
    const engineStatus = mod.ccall("goss_engine_create", "number", ["number", "number"], [0, engineOut]);
    const handle = mod.getValue(engineOut, "i32");
    mod.ccall("goss_free", null, ["number", "number"], [engineOut, 4]);
    if (engineStatus !== GOSS_OK) throw new Error(`engine create failed: ${engineStatus}`);

    const selectorPtr = mod.stringToNewUTF8(`#${canvas.id}`);
    const rendererDescPtr = mod.ccall("goss_alloc", "number", ["number"], [12]);
    mod.setValue(rendererDescPtr, selectorPtr, "i32");
    mod.setValue(rendererDescPtr + 4, canvas.width, "i32");
    mod.setValue(rendererDescPtr + 8, canvas.height, "i32");
    // bgfx's own HTML5 backend creates this canvas's WebGL2 context
    // itself, via emscripten_webgl_create_context - passing
    // webGLContextAttributes here has no effect regardless,
    // preserveDrawingBuffer stays false. Worked around in capturePixels.
    const rendererStatus = await mod.ccall("goss_engine_init_renderer", "number", ["number", "number"], [handle, rendererDescPtr], { async: true });
    mod.ccall("goss_free", null, ["number", "number"], [rendererDescPtr, 12]);
    if (rendererStatus !== GOSS_OK) throw new Error(`renderer init failed: ${rendererStatus}`);

    // The same canvas Emscripten's C++ side just created its own
    // rendering context on - browsers return the existing context for
    // a repeat getContext call on one canvas, so this is that same
    // context, not a second independent one. Which type depends on
    // which build was loaded: try webgpu first since a canvas already
    // bound to 'webgpu' returns null (not the webgl2 context) from a
    // mismatched getContext("webgl2") call.
    const gl = canvas.getContext("webgpu") ? null : canvas.getContext("webgl2");

    return new Engine(mod, handle, canvas, gl);
  }

  resize(width: number, height: number): void {
    this.canvas.width = width;
    this.canvas.height = height;
    this.mod.ccall("goss_engine_resize", null, ["number", "number", "number"], [this.handle, width, height]);
  }

  /// A null session presents the clear color, matching every other
  /// shell's own goss_engine_render_frame contract.
  renderFrame(session: Session | null): number {
    return this.mod.ccall("goss_engine_render_frame", "number", ["number", "number"], [this.handle, session?.handle ?? 0]);
  }

  /// The two ways this shell reads pixels back: bgfx's WebGL2 context
  /// never preserves its drawing buffer, so readPixels runs right after
  /// a fresh render; WebGPU has no sync equivalent, so
  /// goss_engine_capture_frame runs async, mapping a GPU buffer.
  private async capturePixels(session: Session | null): Promise<{ pixels: Uint8Array; width: number; height: number }> {
    if (this.gl) {
      const gl = this.gl;
      this.renderFrame(session);
      const width = this.canvas.width;
      const height = this.canvas.height;
      const pixels = new Uint8Array(width * height * 4);
      gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
      return { pixels, width, height };
    }

    const capacity = this.canvas.width * this.canvas.height * 4;
    const dataPtr = this.mod.ccall("goss_alloc", "number", ["number"], [capacity]);
    const outWidthPtr = this.mod.ccall("goss_alloc", "number", ["number"], [4]);
    const outHeightPtr = this.mod.ccall("goss_alloc", "number", ["number"], [4]);
    this.captureInFlight = true;
    try {
      const status = await this.mod.ccall(
        "goss_engine_capture_frame",
        "number",
        ["number", "number", "number", "number", "number", "number"],
        [this.handle, session?.handle ?? 0, dataPtr, capacity, outWidthPtr, outHeightPtr],
        { async: true },
      );
      if (status !== GOSS_OK) throw new Error(`goss_engine_capture_frame failed: status ${status}`);
      const width = this.mod.getValue(outWidthPtr, "i32");
      const height = this.mod.getValue(outHeightPtr, "i32");
      const pixels = this.mod.HEAPU8.slice(dataPtr, dataPtr + width * height * 4);
      return { pixels, width, height };
    } finally {
      this.captureInFlight = false;
      this.mod.ccall("goss_free", null, ["number", "number"], [dataPtr, capacity]);
      this.mod.ccall("goss_free", null, ["number", "number"], [outWidthPtr, 4]);
      this.mod.ccall("goss_free", null, ["number", "number"], [outHeightPtr, 4]);
    }
  }

  /// goss_engine_capture_frame on the WebGPU build is an async
  /// (Asyncify-suspending) ccall - calling renderFrame while one is in
  /// flight would reenter the wasm module synchronously, which
  /// Asyncify does not support while already suspended.
  get isCaptureInFlight(): boolean {
    return this.captureInFlight;
  }

  /// PNG-encodes the current frame. Test/debug tooling: a real image
  /// beats a frame-sum heuristic for verifying a landmark-driven effect
  /// actually landed where it should, not just that something changed
  /// somewhere.
  async captureFrame(session: Session | null): Promise<string> {
    const { pixels, width: w, height: h } = await this.capturePixels(session);
    const out = document.createElement("canvas");
    out.width = w;
    out.height = h;
    const ctx = out.getContext("2d")!;
    const imageData = ctx.createImageData(w, h);
    if (this.gl) {
      const rowBytes = w * 4;
      for (let y = 0; y < h; y += 1) {
        const srcStart = (h - 1 - y) * rowBytes;
        imageData.data.set(pixels.subarray(srcStart, srcStart + rowBytes), y * rowBytes);
      }
    } else {
      imageData.data.set(pixels);
    }
    ctx.putImageData(imageData, 0, 0);
    return out.toDataURL("image/png");
  }

  async readCenterPixel(session: Session | null): Promise<Uint8Array> {
    const { pixels, width, height } = await this.capturePixels(session);
    const offset = (Math.floor(height / 2) * width + Math.floor(width / 2)) * 4;
    return pixels.slice(offset, offset + 4);
  }

  /// Sums every RGBA byte over the whole canvas - courser but far more
  /// robust than one fixed pixel, since a synthetic test pattern
  /// (Chrome's fake capture device) is free to put its "lit" content
  /// anywhere, leaving any single coordinate dark for long stretches.
  async readFrameSum(session: Session | null): Promise<number> {
    const { pixels } = await this.capturePixels(session);
    let sum = 0;
    for (const value of pixels) sum += value;
    return sum;
  }

  destroy(): void {
    this.mod.ccall("goss_engine_destroy", null, ["number"], [this.handle]);
  }
}

/// Per-preview runtime: frame submission, beauty, tracking, lens. Owns
/// its own scratch allocations (frame descriptor, pixel buffer,
/// landmarks) rather than one shared per-engine pool - matches every
/// other shell's own per-session confinement.
export class Session {
  private frameWidth = 0;
  private frameHeight = 0;
  /// Some cameras (certain external/virtual devices on macOS) hand the
  /// browser frames pre-rotated 180 degrees. Carried as a quarter-turn
  /// count on the submitted frame's own flags, the same mechanism
  /// every other shell uses for sensor orientation.
  private videoFlipped = false;
  private whitenLutsLoaded = 0;
  private lipstickTextureLoaded = false;
  private blushTextureLoaded = false;
  /// Reused across frames, grown on resize rather than alloc/freed every
  /// tick - the frame descriptor is a fixed 32 bytes, the pixel buffer
  /// tracks the video's current resolution.
  private readonly frameDescPtr: number;
  private framePixelsPtr = 0;
  private framePixelsCapacity = 0;
  /// Fixed capacity: FACE_LANDMARK_COUNT never changes.
  private readonly landmarksPtr: number;

  private constructor(
    private readonly mod: EngineModule,
    readonly handle: number,
  ) {
    this.frameDescPtr = mod.ccall("goss_alloc", "number", ["number"], [32]);
    this.landmarksPtr = mod.ccall("goss_alloc", "number", ["number"], [FACE_LANDMARK_COUNT * 3 * 4]);
  }

  static create(engine: Engine, gosslens: Gosslens): Session {
    const mod = gosslens.module;
    const sessionOut = mod.ccall("goss_alloc", "number", ["number"], [4]);
    const status = mod.ccall("goss_session_create", "number", ["number", "number", "number"], [engine.handle, 0, sessionOut]);
    const handle = mod.getValue(sessionOut, "i32");
    mod.ccall("goss_free", null, ["number", "number"], [sessionOut, 4]);
    if (status !== GOSS_OK) throw new Error(`session create failed: ${status}`);
    return new Session(mod, handle);
  }

  setWhiten(amount: number): void {
    this.setBeauty(BeautyEffect.Whiten, this.whitenLutsLoaded === 4 ? amount : 0);
  }

  setSmooth(amount: number): void {
    this.setBeauty(BeautyEffect.Smooth, amount);
  }

  setThinFace(amount: number): void {
    this.setBeauty(BeautyEffect.ThinFace, amount);
  }

  setBigEye(amount: number): void {
    this.setBeauty(BeautyEffect.BigEye, amount);
  }

  setLipstick(amount: number): void {
    this.setBeauty(BeautyEffect.Lipstick, this.lipstickTextureLoaded ? amount : 0);
  }

  setBlush(amount: number): void {
    this.setBeauty(BeautyEffect.Blush, this.blushTextureLoaded ? amount : 0);
  }

  setBeauty(effect: BeautyEffect, amount: number): void {
    this.mod.ccall("goss_session_set_beauty", "number", ["number", "number", "number"], [this.handle, effect, amount]);
  }

  /// Activates a lens from its manifest JSON directly (goss_session_
  /// activate_lens, not the directory-based variant) - the only
  /// activation path this build actually supports: has_file_io is
  /// comptime-false for every wasm target, so goss_session_activate_lens_
  /// from_directory always reports unsupported here, and shader.pass/
  /// lut.pass/blend.pass nodes need compiled resources a bundle
  /// directory would provide that this shell has no way to supply yet.
  /// A lens built entirely from beauty.* nodes (beauty-baseline, say)
  /// activates and runs for real regardless, since those go through
  /// applyWebBeautyChain's own embedded shaders, not a per-lens one.
  activateLens(manifestJson: string): void {
    const bytes = new TextEncoder().encode(manifestJson);
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [bytes.length]);
    this.mod.HEAPU8.set(bytes, ptr);
    this.mod.ccall("goss_session_activate_lens", "number", ["number", "number", "number"], [this.handle, ptr, bytes.length]);
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, bytes.length]);
  }

  deactivateLens(): void {
    this.mod.ccall("goss_session_deactivate_lens", null, ["number"], [this.handle]);
  }

  /// Advances the active lens's triggers/param ramps by dtUs. No face/
  /// hands/tap/world/audio signal is live here - every signal reads as
  /// false/zero, so only triggers with no `when` gate (or ones already
  /// satisfied by a default) actually fire. Real signal wiring is
  /// future work; this is enough to prove a lens activates and ticks
  /// deterministically at all.
  tickLens(dtUs: number): void {
    const signalsPtr = this.mod.ccall("goss_alloc", "number", ["number"], [232]);
    this.mod.HEAPU8.fill(0, signalsPtr, signalsPtr + 232);
    this.mod.ccall("goss_session_tick_lens", "number", ["number", "number", "number"], [this.handle, dtUs, signalsPtr]);
    this.mod.ccall("goss_free", null, ["number", "number"], [signalsPtr, 232]);
  }

  setVideoFlip(enabled: boolean): void {
    this.videoFlipped = enabled;
  }

  isVideoFlipped(): boolean {
    return this.videoFlipped;
  }

  /// landmarks are raw tracker output - x, y in sourceWidth/sourceHeight
  /// pixels (whatever resolution the caller's own tracking pass ran
  /// at, which need not match the live video's own resolution), z in
  /// the same relative scale, three floats per point, matching
  /// goss_face_result's own convention. Scaled here to the frame
  /// currently being rendered - the engine's own contour math expects
  /// "frame pixels" of the frame it's compositing, not of whatever
  /// analysis resolution tracking happened to use. Null clears
  /// tracking (no face this frame).
  setFaceLandmarks(landmarks: Float32Array | null, sourceWidth: number, sourceHeight: number): void {
    if (!landmarks || landmarks.length === 0 || this.frameWidth === 0) {
      this.mod.ccall("goss_session_set_face_landmarks", "number", ["number", "number", "number"], [this.handle, 0, 0]);
      return;
    }
    const scaleX = this.frameWidth / sourceWidth;
    const scaleY = this.frameHeight / sourceHeight;
    const pointCount = landmarks.length / 3;
    const base = this.landmarksPtr >> 2;
    for (let at = 0; at < pointCount; at += 1) {
      this.mod.HEAPF32[base + at * 3] = landmarks[at * 3]! * scaleX;
      this.mod.HEAPF32[base + at * 3 + 1] = landmarks[at * 3 + 1]! * scaleY;
      this.mod.HEAPF32[base + at * 3 + 2] = landmarks[at * 3 + 2]!;
    }
    this.mod.ccall(
      "goss_session_set_face_landmarks",
      "number",
      ["number", "number", "number"],
      [this.handle, this.landmarksPtr, pointCount],
    );
  }

  /// Uploads one of whiten's four lookup textures directly - slot 0
  /// gray, 1 origin, 2 skin, 3 custom. loadWhitenLuts is the sugar most
  /// callers want; this is the raw upload it calls internally.
  setBeautyLut(slot: number, rgba: Uint8ClampedArray | Uint8Array, width: number, height: number): void {
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [rgba.length]);
    this.mod.HEAPU8.set(rgba, ptr);
    this.mod.ccall(
      "goss_session_set_beauty_lut",
      "number",
      ["number", "number", "number", "number", "number"],
      [this.handle, slot, ptr, width, height],
    );
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, rgba.length]);
  }

  /// Uploads lipstick's or blush's own source image directly.
  /// loadMakeupTextures is the sugar most callers want; this is the raw
  /// upload it calls internally.
  setBeautyMakeupTexture(effect: BeautyEffect, rgba: Uint8ClampedArray | Uint8Array, width: number, height: number): void {
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [rgba.length]);
    this.mod.HEAPU8.set(rgba, ptr);
    this.mod.ccall(
      "goss_session_set_beauty_makeup_texture",
      "number",
      ["number", "number", "number", "number", "number"],
      [this.handle, effect, ptr, width, height],
    );
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, rgba.length]);
  }

  /// Fetches the four whiten lookup textures (gray/origin/skin/custom),
  /// relative to lutBaseUrl. Safe to call once after construction;
  /// setWhiten stays a no-op until this resolves.
  async loadWhitenLuts(lutBaseUrl: string | URL): Promise<void> {
    const names = ["lookup_gray", "lookup_origin", "lookup_skin", "lookup_light"];
    const images = await Promise.all(
      names.map((name) => fetch(new URL(`${name}.png`, lutBaseUrl)).then((r) => r.blob()).then(decodeImageRgba)),
    );
    images.forEach((image, slot) => {
      this.setBeautyLut(slot, image.data, image.width, image.height);
      this.whitenLutsLoaded += 1;
    });
  }

  /// Fetches mouth.png/blusher.png, relative to baseUrl. Safe to call
  /// once after construction; setLipstick/setBlush stay a no-op until
  /// this resolves.
  async loadMakeupTextures(baseUrl: string | URL): Promise<void> {
    const [mouth, blusher] = await Promise.all(
      ["mouth.png", "blusher.png"].map((name) => fetch(new URL(name, baseUrl)).then((r) => r.blob()).then(decodeImageRgba)),
    );
    for (const [effect, image] of [
      [BeautyEffect.Lipstick, mouth],
      [BeautyEffect.Blush, blusher],
    ] as const) {
      this.setBeautyMakeupTexture(effect, image.data, image.width, image.height);
    }
    this.lipstickTextureLoaded = true;
    this.blushTextureLoaded = true;
  }

  private ensureFramePixels(byteLength: number): void {
    if (this.framePixelsCapacity >= byteLength) return;
    if (this.framePixelsPtr !== 0) this.mod.ccall("goss_free", null, ["number", "number"], [this.framePixelsPtr, this.framePixelsCapacity]);
    this.framePixelsPtr = this.mod.ccall("goss_alloc", "number", ["number"], [byteLength]);
    this.framePixelsCapacity = byteLength;
  }

  submitFrameRgbaCopy(rgba: Uint8ClampedArray, width: number, height: number, mirror: boolean): void {
    this.frameWidth = width;
    this.frameHeight = height;
    const byteLength = width * height * 4;
    this.ensureFramePixels(byteLength);
    this.mod.HEAPU8.set(rgba, this.framePixelsPtr);

    const rotationQuarters = this.videoFlipped ? 2 : 0;
    const flags = (mirror ? FRAME_FLAG_MIRROR : 0) | (rotationQuarters << FRAME_ROTATION_SHIFT);
    this.mod.setValue(this.frameDescPtr, width, "i32");
    this.mod.setValue(this.frameDescPtr + 4, height, "i32");
    this.mod.setValue(this.frameDescPtr + 8, PIXEL_FORMAT_RGBA8, "i32");
    this.mod.setValue(this.frameDescPtr + 12, 0, "i32");
    this.mod.setValue(this.frameDescPtr + 16, 0, "i32");
    this.mod.setValue(this.frameDescPtr + 20, flags, "i32");
    const timestampUs = Math.round(performance.now() * 1000);
    this.mod.setValue(this.frameDescPtr + 24, timestampUs >>> 0, "i32");
    this.mod.setValue(this.frameDescPtr + 28, Math.floor(timestampUs / 4294967296), "i32");

    this.mod.ccall(
      "goss_session_submit_frame_rgba_copy",
      "number",
      ["number", "number", "number", "number"],
      [this.handle, this.frameDescPtr, this.framePixelsPtr, width * 4],
    );
  }

  /// thermal is always nominal: no browser API surfaces device thermal
  /// state the way Kotlin/Swift's own OS-level thermal signal does.
  reportFrame(frameTimeUs: number): void {
    this.mod.ccall("goss_session_report_frame", "number", ["number", "number", "number"], [this.handle, frameTimeUs, 0]);
  }

  degradeLevel(): DegradeLevel {
    return this.mod.ccall("goss_session_degrade_level", "number", ["number"], [this.handle]);
  }

  destroy(): void {
    this.mod.ccall("goss_session_destroy", null, ["number"], [this.handle]);
  }
}

/// The shell-facing orchestrator: capture loop, video element, DOM
/// events. Composes Gosslens/Engine/Session rather than being one of
/// them - the same relationship CameraController/PreviewViewController
/// have to Engine/Session on iOS, not a fourth ABI-shaped type.
export class PreviewSession {
  readonly video = document.createElement("video");
  state: CaptureState = "idle";

  private stream: MediaStream | null = null;
  private raf = 0;
  private lastTick = 0;
  private fpsWindowStart = 0;
  private fpsWindowFrames = 0;
  private renderedFrames = 0;
  private cameraFrames = 0;
  private lastVideoTime = -1;
  private scratchCanvas = document.createElement("canvas");
  private scratchCtx: CanvasRenderingContext2D;

  private constructor(
    readonly gosslens: Gosslens,
    readonly engine: Engine,
    readonly session: Session,
    private events: SessionEvents,
  ) {
    this.scratchCtx = this.scratchCanvas.getContext("2d", { willReadFrequently: true })!;
  }

  static async create(canvas: HTMLCanvasElement, wasmJsUrl: string | URL, events: SessionEvents = {}): Promise<PreviewSession> {
    const gosslens = await Gosslens.load(canvas, wasmJsUrl);
    const engine = await Engine.create(gosslens, canvas);
    const session = Session.create(engine, gosslens);
    return new PreviewSession(gosslens, engine, session, events);
  }

  get abiVersion(): number {
    return this.gosslens.abiVersion;
  }

  private setState(state: CaptureState): void {
    this.state = state;
    this.events.onState?.(state);
  }

  setWhiten(amount: number): void {
    this.session.setWhiten(amount);
  }

  setSmooth(amount: number): void {
    this.session.setSmooth(amount);
  }

  setThinFace(amount: number): void {
    this.session.setThinFace(amount);
  }

  setBigEye(amount: number): void {
    this.session.setBigEye(amount);
  }

  setLipstick(amount: number): void {
    this.session.setLipstick(amount);
  }

  setBlush(amount: number): void {
    this.session.setBlush(amount);
  }

  activateLens(manifestJson: string): void {
    this.session.activateLens(manifestJson);
  }

  deactivateLens(): void {
    this.session.deactivateLens();
  }

  tickLens(dtUs: number): void {
    this.session.tickLens(dtUs);
  }

  setVideoFlip(enabled: boolean): void {
    this.session.setVideoFlip(enabled);
  }

  isVideoFlipped(): boolean {
    return this.session.isVideoFlipped();
  }

  setFaceLandmarks(landmarks: Float32Array | null, sourceWidth: number, sourceHeight: number): void {
    this.session.setFaceLandmarks(landmarks, sourceWidth, sourceHeight);
  }

  loadWhitenLuts(lutBaseUrl: string | URL): Promise<void> {
    return this.session.loadWhitenLuts(lutBaseUrl);
  }

  loadMakeupTextures(baseUrl: string | URL): Promise<void> {
    return this.session.loadMakeupTextures(baseUrl);
  }

  /// Uploads a still image directly into the frame the engine renders,
  /// bypassing the video element - freezeCamera() first stops tick()
  /// from re-submitting over it. Test/demo tooling only: skin-smoothing's
  /// content-adaptive blend needs a real face to prove, not a fake one.
  async loadStillFrame(url: string): Promise<void> {
    const image = await decodeImageRgba(await (await fetch(url)).blob(), {
      maxWidth: this.scratchCanvas.width,
      maxHeight: this.scratchCanvas.height,
    });
    // Not mirrored: a loaded test photo isn't a front camera, and
    // setLandmarksFromStill tracks this same unmirrored image - mirroring
    // only the background here would leave the tracked landmarks
    // pointing at the wrong side of the now-mirrored face.
    this.session.submitFrameRgbaCopy(image.data, image.width, image.height, false);
  }

  async start(): Promise<void> {
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({
        video: { width: { ideal: 1280 }, height: { ideal: 720 } },
        audio: false,
      });
    } catch (err) {
      this.setState(err instanceof DOMException && err.name === "NotAllowedError" ? "denied" : "failed");
      return;
    }
    const track = this.stream.getVideoTracks()[0];
    track.addEventListener("mute", () => this.setState("interrupted"));
    track.addEventListener("unmute", () => this.setState("running"));
    track.addEventListener("ended", () => this.setState("failed"));

    this.video.srcObject = this.stream;
    this.video.muted = true;
    this.video.playsInline = true;
    await this.video.play();
    this.setState("running");
    this.fpsWindowStart = performance.now();
    this.lastTick = performance.now();
    this.tick();
  }

  stop(): void {
    cancelAnimationFrame(this.raf);
    this.stream?.getTracks().forEach((track) => track.stop());
    this.stream = null;
    this.setState("idle");
  }

  private tick = (): void => {
    this.raf = requestAnimationFrame(this.tick);
    if (this.engine.isCaptureInFlight) return;
    const now = performance.now();
    const frameTimeUs = Math.max(0, Math.round((now - this.lastTick) * 1000));
    this.lastTick = now;
    this.session.reportFrame(frameTimeUs);

    if (this.video.readyState >= 2 && this.video.currentTime !== this.lastVideoTime) {
      this.lastVideoTime = this.video.currentTime;
      this.cameraFrames += 1;
      const width = this.video.videoWidth;
      const height = this.video.videoHeight;
      this.scratchCanvas.width = width;
      this.scratchCanvas.height = height;
      this.scratchCtx.drawImage(this.video, 0, 0, width, height);
      const pixels = this.scratchCtx.getImageData(0, 0, width, height);
      // Not mirrored here - the demo page's own CSS mirrors the canvas
      // for display, so the engine keeps working in the camera's real,
      // unmirrored coordinate space (matching tracking, which analyzes
      // this same unmirrored buffer).
      this.session.submitFrameRgbaCopy(pixels.data, width, height, false);
    }

    const status = this.engine.renderFrame(this.session);
    if (status === GOSS_OK) {
      this.renderedFrames += 1;
      this.fpsWindowFrames += 1;
    }

    if (now - this.fpsWindowStart >= 1000) {
      const fps = (this.fpsWindowFrames * 1000) / (now - this.fpsWindowStart);
      this.events.onFps?.(fps, this.renderedFrames, this.cameraFrames);
      this.fpsWindowStart = now;
      this.fpsWindowFrames = 0;
    }
  };

  degradeLevel(): DegradeLevel {
    return this.session.degradeLevel();
  }

  captureFrame(): Promise<string> {
    return this.engine.captureFrame(this.session);
  }

  readCenterPixel(): Promise<Uint8Array> {
    return this.engine.readCenterPixel(this.session);
  }

  readFrameSum(): Promise<number> {
    return this.engine.readFrameSum(this.session);
  }
}
