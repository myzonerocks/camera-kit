// The web shell over camerakit_web, the real bgfx-backed engine every
// other shell already runs (Swift/Kotlin call the exact same frozen ABI
// through their own thin platform glue). This shell owns only what the
// browser forces on it - camera capture through getUserMedia, decoding
// PNGs the core has no decoder for, driving the render loop - and hands
// everything else (the frame graph, all six beauty effects, mirror and
// rotation) straight to the engine.

export const CK_OK = 0;

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
  private frameWidth = 0;
  private frameHeight = 0;
  /// Some cameras (seen with certain external/virtual devices on macOS)
  /// hand the browser frames pre-rotated 180 degrees - the raw decoded
  /// video is upside down before any code here touches it. Carried as a
  /// quarter-turn count on the submitted frame's own flags, the same
  /// mechanism every other shell uses for sensor orientation - not a
  /// CSS or texture-upload workaround.
  private videoFlipped = false;
  private whitenLutsLoaded = 0;
  private lipstickTextureLoaded = false;
  private blushTextureLoaded = false;
  private scratchCanvas = document.createElement("canvas");
  private scratchCtx: CanvasRenderingContext2D;
  /// Reused across frames, grown on resize rather than alloc/freed every
  /// tick - the frame descriptor is a fixed 32 bytes, the pixel buffer
  /// tracks the video's current resolution.
  private frameDescPtr: number;
  private framePixelsPtr = 0;
  private framePixelsCapacity = 0;
  /// Fixed capacity: FACE_LANDMARK_COUNT never changes.
  private landmarksPtr: number;

  private constructor(
    private mod: EngineModule,
    private engine: number,
    private session: number,
    private canvas: HTMLCanvasElement,
    private gl: WebGL2RenderingContext,
    private events: SessionEvents,
    readonly abiVersion: number,
  ) {
    this.scratchCtx = this.scratchCanvas.getContext("2d", { willReadFrequently: true })!;
    this.frameDescPtr = mod.ccall("ck_alloc", "number", ["number"], [32]);
    this.landmarksPtr = mod.ccall("ck_alloc", "number", ["number"], [FACE_LANDMARK_COUNT * 3 * 4]);
  }

  /// Loads camerakit_web.js (a real ES module - see build.zig) and
  /// stands up the engine, renderer, and session against canvas. A
  /// dynamic import, not a static one: bun's bundler would otherwise
  /// try to inline/transform this file, which would break Emscripten's
  /// own import.meta.url-relative fetch of camerakit_web.wasm sitting
  /// next to it.
  static async create(canvas: HTMLCanvasElement, wasmJsUrl: string | URL, events: SessionEvents = {}): Promise<PreviewSession> {
    if (!canvas.id) throw new Error("canvas needs a stable id for bgfx's own selector lookup");
    const imported = (await import(/* @vite-ignore */ String(wasmJsUrl))) as { default: EngineModuleFactory };
    // bgfx's own HTML5 backend creates this canvas's WebGL2 context
    // itself, in C++, via emscripten_webgl_create_context - confirmed
    // by real render capture: passing webGLContextAttributes here (the
    // documented Emscripten Module override) has no effect at all,
    // getContextAttributes() still reports preserveDrawingBuffer false
    // regardless. bgfx's own context creation isn't something this
    // shell can reach without patching vendored source, which this
    // project doesn't do - readCenterPixel/readFrameSum below work
    // around it by reading immediately after a fresh render instead.
    const mod = await imported.default({ canvas });

    const version = mod.ccall("ck_abi_version", "number", [], []) >>> 0;
    if (version >> 16 !== 0) throw new Error(`camerakit abi major mismatch: ${version >> 16}`);

    const engineOut = mod.ccall("ck_alloc", "number", ["number"], [4]);
    const engineStatus = mod.ccall("ck_engine_create", "number", ["number", "number"], [0, engineOut]);
    const engine = mod.getValue(engineOut, "i32");
    mod.ccall("ck_free", null, ["number", "number"], [engineOut, 4]);
    if (engineStatus !== CK_OK) throw new Error(`engine create failed: ${engineStatus}`);

    // bgfx's HTML5 backend resolves its own canvas via this selector
    // string (glcontext_html5.cpp, not documented in the C header) -
    // Module.canvas above is Emscripten's own, separate mechanism for
    // the same canvas; both need to agree.
    const selectorPtr = mod.stringToNewUTF8(`#${canvas.id}`);
    const rendererDescPtr = mod.ccall("ck_alloc", "number", ["number"], [12]);
    mod.setValue(rendererDescPtr, selectorPtr, "i32");
    mod.setValue(rendererDescPtr + 4, canvas.width, "i32");
    mod.setValue(rendererDescPtr + 8, canvas.height, "i32");
    const rendererStatus = mod.ccall("ck_engine_init_renderer", "number", ["number", "number"], [engine, rendererDescPtr]);
    mod.ccall("ck_free", null, ["number", "number"], [rendererDescPtr, 12]);
    if (rendererStatus !== CK_OK) throw new Error(`renderer init failed: ${rendererStatus}`);

    const sessionOut = mod.ccall("ck_alloc", "number", ["number"], [4]);
    const sessionStatus = mod.ccall("ck_session_create", "number", ["number", "number", "number"], [engine, 0, sessionOut]);
    const session = mod.getValue(sessionOut, "i32");
    mod.ccall("ck_free", null, ["number", "number"], [sessionOut, 4]);
    if (sessionStatus !== CK_OK) throw new Error(`session create failed: ${sessionStatus}`);

    // The same canvas Emscripten just created its own WebGL2 context on
    // - browsers return the existing context for a repeat getContext
    // call on one canvas, so this is that same context, not a second
    // independent one.
    const gl = canvas.getContext("webgl2");
    if (!gl) throw new Error("webgl2 unavailable");

    return new PreviewSession(mod, engine, session, canvas, gl, events, version);
  }

  private setState(state: CaptureState): void {
    this.state = state;
    this.events.onState?.(state);
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

  private setBeauty(effect: BeautyEffect, amount: number): void {
    this.mod.ccall("ck_session_set_beauty", "number", ["number", "number", "number"], [this.session, effect, amount]);
  }

  /// Activates a lens from its manifest JSON directly (ck_session_
  /// activate_lens, not the directory-based variant) - the only
  /// activation path this build actually supports: has_file_io is
  /// comptime-false for every wasm target, so ck_session_activate_lens_
  /// from_directory always reports unsupported here, and shader.pass/
  /// lut.pass/blend.pass nodes need compiled resources a bundle
  /// directory would provide that this shell has no way to supply yet.
  /// A lens built entirely from beauty.* nodes (beauty-baseline, say)
  /// activates and runs for real regardless, since those go through
  /// applyWebBeautyChain's own embedded shaders, not a per-lens one.
  activateLens(manifestJson: string): void {
    const bytes = new TextEncoder().encode(manifestJson);
    const ptr = this.mod.ccall("ck_alloc", "number", ["number"], [bytes.length]);
    this.mod.HEAPU8.set(bytes, ptr);
    this.mod.ccall("ck_session_activate_lens", "number", ["number", "number", "number"], [this.session, ptr, bytes.length]);
    this.mod.ccall("ck_free", null, ["number", "number"], [ptr, bytes.length]);
  }

  deactivateLens(): void {
    this.mod.ccall("ck_session_deactivate_lens", null, ["number"], [this.session]);
  }

  /// Advances the active lens's triggers/param ramps by dtUs. No face/
  /// hands/tap/world/audio signal is live here - every signal reads as
  /// false/zero, so only triggers with no `when` gate (or ones already
  /// satisfied by a default) actually fire. Real signal wiring is
  /// future work; this is enough to prove a lens activates and ticks
  /// deterministically at all.
  tickLens(dtUs: number): void {
    const signalsPtr = this.mod.ccall("ck_alloc", "number", ["number"], [232]);
    this.mod.HEAPU8.fill(0, signalsPtr, signalsPtr + 232);
    this.mod.ccall("ck_session_tick_lens", "number", ["number", "number", "number"], [this.session, dtUs, signalsPtr]);
    this.mod.ccall("ck_free", null, ["number", "number"], [signalsPtr, 232]);
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
  /// ck_face_result's own convention. Scaled here to the frame
  /// currently being rendered - the engine's own contour math expects
  /// "frame pixels" of the frame it's compositing, not of whatever
  /// analysis resolution tracking happened to use. Null clears
  /// tracking (no face this frame).
  setFaceLandmarks(landmarks: Float32Array | null, sourceWidth: number, sourceHeight: number): void {
    if (!landmarks || landmarks.length === 0 || this.frameWidth === 0) {
      this.mod.ccall("ck_session_set_face_landmarks", "number", ["number", "number", "number"], [this.session, 0, 0]);
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
      "ck_session_set_face_landmarks",
      "number",
      ["number", "number", "number"],
      [this.session, this.landmarksPtr, pointCount],
    );
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
      const ptr = this.mod.ccall("ck_alloc", "number", ["number"], [image.data.length]);
      this.mod.HEAPU8.set(image.data, ptr);
      this.mod.ccall(
        "ck_session_set_beauty_lut",
        "number",
        ["number", "number", "number", "number", "number"],
        [this.session, slot, ptr, image.width, image.height],
      );
      this.mod.ccall("ck_free", null, ["number", "number"], [ptr, image.data.length]);
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
      const ptr = this.mod.ccall("ck_alloc", "number", ["number"], [image.data.length]);
      this.mod.HEAPU8.set(image.data, ptr);
      this.mod.ccall(
        "ck_session_set_beauty_makeup_texture",
        "number",
        ["number", "number", "number", "number", "number"],
        [this.session, effect, ptr, image.width, image.height],
      );
      this.mod.ccall("ck_free", null, ["number", "number"], [ptr, image.data.length]);
    }
    this.lipstickTextureLoaded = true;
    this.blushTextureLoaded = true;
  }

  /// Uploads a still image directly into the frame the engine renders,
  /// bypassing the video element entirely - freezeCamera() first stops
  /// tick() from re-submitting over it on the next frame. Test/demo
  /// tooling only (skin-smoothing's content-adaptive blend needs a real
  /// face to prove, not Chrome's fake capture device's own pattern).
  async loadStillFrame(url: string): Promise<void> {
    const image = await decodeImageRgba(await (await fetch(url)).blob(), {
      maxWidth: this.canvas.width,
      maxHeight: this.canvas.height,
    });
    // Not mirrored: a loaded test photo isn't a front camera, and
    // setLandmarksFromStill tracks this same unmirrored image - mirroring
    // only the background here would leave the tracked landmarks
    // pointing at the wrong side of the now-mirrored face.
    this.submitRgbaFrame(image.data, image.width, image.height, false);
  }

  private ensureFramePixels(byteLength: number): void {
    if (this.framePixelsCapacity >= byteLength) return;
    if (this.framePixelsPtr !== 0) this.mod.ccall("ck_free", null, ["number", "number"], [this.framePixelsPtr, this.framePixelsCapacity]);
    this.framePixelsPtr = this.mod.ccall("ck_alloc", "number", ["number"], [byteLength]);
    this.framePixelsCapacity = byteLength;
  }

  private submitRgbaFrame(rgba: Uint8ClampedArray, width: number, height: number, mirror: boolean): void {
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
      "ck_session_submit_frame_rgba_copy",
      "number",
      ["number", "number", "number", "number"],
      [this.session, this.frameDescPtr, this.framePixelsPtr, width * 4],
    );
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
    const now = performance.now();
    const frameTimeUs = Math.max(0, Math.round((now - this.lastTick) * 1000));
    this.lastTick = now;
    this.mod.ccall("ck_session_report_frame", "number", ["number", "number", "number"], [this.session, frameTimeUs, 0]);

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
      this.submitRgbaFrame(pixels.data, width, height, false);
    }

    const status = this.mod.ccall("ck_engine_render_frame", "number", ["number", "number"], [this.engine, this.session]);
    if (status === CK_OK) {
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

  /// bgfx's own WebGL2 context (see the comment on create() above) never
  /// preserves its drawing buffer, so a read has to happen synchronously
  /// right after a fresh render - one JS turn later and the browser has
  /// already presented and cleared it. Both read methods below render
  /// once more immediately before reading rather than trusting whatever
  /// the last rAF tick happened to leave behind.
  private renderForReadback(): void {
    this.mod.ccall("ck_engine_render_frame", "number", ["number", "number"], [this.engine, this.session]);
  }

  /// Renders, reads, and PNG-encodes the canvas in one synchronous
  /// call - same reason readCenterPixel/readFrameSum render right
  /// before reading (bgfx's own context never preserves its drawing
  /// buffer), a caller across an async boundary can't split render and
  /// read into two separate steps either. Test/debug tooling: a real
  /// image beats a frame-sum heuristic for verifying a landmark-driven
  /// effect actually landed where it should, not just that something
  /// changed somewhere.
  captureFrame(): string {
    this.renderForReadback();
    const gl = this.gl;
    const w = this.canvas.width;
    const h = this.canvas.height;
    const pixels = new Uint8Array(w * h * 4);
    gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
    const out = document.createElement("canvas");
    out.width = w;
    out.height = h;
    const ctx = out.getContext("2d")!;
    const imageData = ctx.createImageData(w, h);
    const rowBytes = w * 4;
    for (let y = 0; y < h; y += 1) {
      const srcStart = (h - 1 - y) * rowBytes;
      imageData.data.set(pixels.subarray(srcStart, srcStart + rowBytes), y * rowBytes);
    }
    ctx.putImageData(imageData, 0, 0);
    return out.toDataURL("image/png");
  }

  readCenterPixel(): Uint8Array {
    this.renderForReadback();
    const gl = this.gl;
    const pixel = new Uint8Array(4);
    gl.readPixels(Math.floor(this.canvas.width / 2), Math.floor(this.canvas.height / 2), 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, pixel);
    return pixel;
  }

  degradeLevel(): DegradeLevel {
    return this.mod.ccall("ck_session_degrade_level", "number", ["number"], [this.session]);
  }

  /// Sums every RGBA byte over the whole canvas - a courser but far more
  /// robust brightness/content probe than one fixed pixel, since a
  /// synthetic test pattern (Chrome's fake capture device, say) is free
  /// to put its own "lit" content anywhere and leave any single fixed
  /// coordinate dark for long stretches.
  readFrameSum(): number {
    this.renderForReadback();
    const gl = this.gl;
    const pixels = new Uint8Array(this.canvas.width * this.canvas.height * 4);
    gl.readPixels(0, 0, this.canvas.width, this.canvas.height, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
    let sum = 0;
    for (const value of pixels) sum += value;
    return sum;
  }
}
