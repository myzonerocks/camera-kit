// The web shell over the camerakit wasm core. Framework-free: the package
// exposes the same shapes as the other shells and owns only what the
// platform forces on it, capture through getUserMedia and the GPU surface
// through WebGL2. Session accounting, degradation, and color math all come
// from the core.

export const CK_OK = 0;

export const enum DegradeLevel {
  Full = 0,
  ReducedMlCadence = 1,
  SegmentationOff = 2,
  BeautySimplified = 3,
  Passthrough = 4,
}

interface CoreExports {
  memory: WebAssembly.Memory;
  ck_abi_version(): number;
  ck_alloc(size: number): number;
  ck_free(ptr: number, size: number): void;
  ck_engine_create(config: number, out: number): number;
  ck_engine_destroy(engine: number): void;
  ck_session_create(engine: number, config: number, out: number): number;
  ck_session_destroy(session: number): void;
  ck_session_report_frame(session: number, frameTimeUs: number, thermal: number): number;
  ck_session_degrade_level(session: number): number;
  ck_color_yuv_to_rgb(standard: number, range: number, outMatrix: number): number;
}

export class Core {
  private constructor(private exports: CoreExports) {}

  static async load(wasmUrl: string | URL): Promise<Core> {
    const response = await fetch(wasmUrl);
    const { instance } = await WebAssembly.instantiateStreaming(response, {});
    const core = new Core(instance.exports as unknown as CoreExports);
    const version = core.abiVersion();
    if (version >> 16 !== 0) {
      throw new Error(`camerakit abi major mismatch: ${version >> 16}`);
    }
    return core;
  }

  abiVersion(): number {
    return this.exports.ck_abi_version() >>> 0;
  }

  createEngine(): number {
    const out = this.exports.ck_alloc(4);
    try {
      if (this.exports.ck_engine_create(0, out) !== CK_OK) {
        throw new Error("engine create failed");
      }
      return new DataView(this.exports.memory.buffer).getUint32(out, true);
    } finally {
      this.exports.ck_free(out, 4);
    }
  }

  destroyEngine(engine: number): void {
    this.exports.ck_engine_destroy(engine);
  }

  createSession(engine: number): number {
    const out = this.exports.ck_alloc(4);
    try {
      if (this.exports.ck_session_create(engine, 0, out) !== CK_OK) {
        throw new Error("session create failed");
      }
      return new DataView(this.exports.memory.buffer).getUint32(out, true);
    } finally {
      this.exports.ck_free(out, 4);
    }
  }

  destroySession(session: number): void {
    this.exports.ck_session_destroy(session);
  }

  reportFrame(session: number, frameTimeUs: number): DegradeLevel {
    return this.exports.ck_session_report_frame(session, frameTimeUs, 0);
  }

  degradeLevel(session: number): DegradeLevel {
    return this.exports.ck_session_degrade_level(session);
  }

  // The exact conversion the core computes, as a column-major mat4 for the
  // shader: rgb = (m * vec4(yuv, 1)).rgb.
  yuvToRgbMatrix(standard: number, range: number): Float32Array {
    const out = this.exports.ck_alloc(64);
    try {
      if (this.exports.ck_color_yuv_to_rgb(standard, range, out) !== CK_OK) {
        throw new Error("invalid color parameters");
      }
      return new Float32Array(this.exports.memory.buffer.slice(out, out + 64));
    } finally {
      this.exports.ck_free(out, 64);
    }
  }
}

export type CaptureState = "idle" | "running" | "denied" | "failed" | "interrupted";

export interface SessionEvents {
  onState?(state: CaptureState): void;
  onFps?(fps: number, renderedFrames: number, cameraFrames: number): void;
}

// Live camera preview: getUserMedia into a video element, each frame uploaded
// to a WebGL2 texture and drawn full-canvas. The browser delivers decoded
// RGB; the raw-plane path with the core's conversion matrix arrives with
// VideoFrame ingestion.
// The skin-smoothing "whiten" look is a tone curve plus a three-stage
// lookup-texture pass, run natively here in WebGL2/GLSL ES rather than
// through a shared native pipeline, since browsers have no way to hand a
// wasm GL context to WebGPU/WebGL2 the way native platforms can.
const WHITEN_LUT_NAMES = ["lookup_gray", "lookup_origin", "lookup_skin", "lookup_light"] as const;

export class PreviewSession {
  private stream: MediaStream | null = null;
  /// The camera element frames render from; analysis passes sample it too.
  readonly video = document.createElement("video");
  private gl: WebGL2RenderingContext;
  private program: WebGLProgram;
  private texture: WebGLTexture;
  private whitenLuts: WebGLTexture[] = [];
  private whitenAmount = 0;
  private whitenUniform: WebGLUniformLocation | null;
  private smoothAmount = 0;
  private smoothUniform: WebGLUniformLocation | null;
  private blurProgram: WebGLProgram;
  private blurStepUniform: WebGLUniformLocation | null;
  private blurTexture: WebGLTexture;
  private blurFbo: WebGLFramebuffer;
  private meanTexture: WebGLTexture;
  private meanFbo: WebGLFramebuffer;
  private meanWidth = 0;
  private meanHeight = 0;
  private frameWidth = 0;
  private frameHeight = 0;
  private raf = 0;
  private lastTick = 0;
  private fpsWindowStart = 0;
  private fpsWindowFrames = 0;
  private renderedFrames = 0;
  private cameraFrames = 0;
  private lastVideoTime = -1;
  state: CaptureState = "idle";

  constructor(
    private core: Core,
    private session: number,
    private canvas: HTMLCanvasElement,
    private events: SessionEvents = {},
  ) {
    // preserveDrawingBuffer keeps the last drawn frame in place between
    // rAF callbacks - without it the browser is free to clear the
    // default framebuffer right after compositing, so anything reading
    // pixels back outside the render loop itself (screenshots, the
    // prover's readPixels calls) can race a blank buffer.
    const gl = canvas.getContext("webgl2", { preserveDrawingBuffer: true });
    if (!gl) throw new Error("webgl2 unavailable");
    this.gl = gl;
    this.program = this.buildProgram();
    this.whitenUniform = gl.getUniformLocation(this.program, "u_whiten");
    this.smoothUniform = gl.getUniformLocation(this.program, "u_smooth");
    const texture = gl.createTexture();
    if (!texture) throw new Error("texture create failed");
    this.texture = texture;
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

    // u_mean stays bound to a fixed unit (5; 1-4 are the whiten LUTs)
    // for the same reason those are: it never changes, only the pixels
    // it points at do, via computeMean re-rendering into it each frame.
    gl.useProgram(this.program);
    gl.uniform1i(gl.getUniformLocation(this.program, "u_mean"), 5);

    this.blurProgram = this.buildBlurProgram();
    this.blurStepUniform = gl.getUniformLocation(this.blurProgram, "u_step");
    const blurTarget = this.createRenderTarget();
    this.blurTexture = blurTarget.texture;
    this.blurFbo = blurTarget.fbo;
    const meanTarget = this.createRenderTarget();
    this.meanTexture = meanTarget.texture;
    this.meanFbo = meanTarget.fbo;
  }

  private setState(state: CaptureState): void {
    this.state = state;
    this.events.onState?.(state);
  }

  /// Zero until the LUT textures actually finish loading, matching the
  /// shader's own `if (u_whiten > 0.0)` skip - the effect degrades to a
  /// no-op rather than sampling unbound textures while the fetch is in
  /// flight.
  setWhiten(amount: number): void {
    this.whitenAmount = this.whitenLuts.length === WHITEN_LUT_NAMES.length ? amount : 0;
  }

  setSmooth(amount: number): void {
    this.smoothAmount = amount;
  }

  /// Fetches and decodes the four LUT textures the whiten pass samples,
  /// relative to lutBaseUrl (the demo's own res/ directory). Safe to
  /// call once after construction; setWhiten stays a no-op until this
  /// resolves.
  async loadWhitenLuts(lutBaseUrl: string | URL): Promise<void> {
    const gl = this.gl;
    const bitmaps = await Promise.all(
      WHITEN_LUT_NAMES.map((name) =>
        fetch(new URL(`${name}.png`, lutBaseUrl))
          .then((r) => r.blob())
          .then((b) => createImageBitmap(b)),
      ),
    );
    this.whitenLuts = bitmaps.map((bitmap) => {
      const tex = gl.createTexture();
      if (!tex) throw new Error("lut texture create failed");
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, bitmap);
      return tex;
    });

    // Each LUT gets its own fixed texture unit (1-4; 0 stays the camera
    // frame) - bound once here since the LUTs themselves never change,
    // unlike u_whiten which tick() updates every frame.
    const samplerNames = ["u_lookupGray", "u_lookupOrigin", "u_lookupSkin", "u_lookupCustom"];
    gl.useProgram(this.program);
    for (const [index, tex] of this.whitenLuts.entries()) {
      gl.activeTexture(gl.TEXTURE1 + index);
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.uniform1i(gl.getUniformLocation(this.program, samplerNames[index]!), 1 + index);
    }
    gl.activeTexture(gl.TEXTURE0);
  }

  private buildProgram(): WebGLProgram {
    const gl = this.gl;
    const vsSource = `#version 300 es
      const vec2 corners[4] = vec2[](vec2(-1.,-1.), vec2(1.,-1.), vec2(1.,1.), vec2(-1.,1.));
      const vec2 uvs[4] = vec2[](vec2(0.,1.), vec2(1.,1.), vec2(1.,0.), vec2(0.,0.));
      out vec2 v_uv;
      void main() {
        gl_Position = vec4(corners[gl_VertexID], 0., 1.);
        v_uv = uvs[gl_VertexID];
      }`;
    // The whiten branch below is a verbatim port of gpupixel's own
    // GLES fragment shader (beauty_face_unit_filter.cc), not a
    // reimplementation - same tone curve constants, same three-stage
    // 4x4-atlas LUT indexing math, same mix/alpha blending.
    const fsSource = `#version 300 es
      precision highp float;
      uniform sampler2D u_frame;
      uniform sampler2D u_mean;
      uniform sampler2D u_lookupGray;
      uniform sampler2D u_lookupOrigin;
      uniform sampler2D u_lookupSkin;
      uniform sampler2D u_lookupCustom;
      uniform float u_smooth;
      uniform float u_whiten;
      in vec2 v_uv;
      out vec4 fragColor;

      const float levelRangeInv = 1.02657;
      const float levelBlack = 0.0258820;
      const float alpha = 0.7;

      void main() {
        vec4 iColor = texture(u_frame, v_uv);
        vec3 color = iColor.rgb;

        // A verbatim port of gpupixel's own skin-smoothing math
        // (beauty_face_unit_filter.cc's blurAlpha branch): u_mean is a
        // wide separable blur of the frame, and how strongly a pixel
        // blends toward it depends on both how flat that area already
        // is (low local variance, estimated here from the difference
        // between the frame and its own blur) and how close it sits to
        // mid-tone (the min/clamp term), so edges and shadows resist
        // smoothing while flat skin doesn't.
        if (u_smooth > 0.0) {
          vec3 meanColor = texture(u_mean, v_uv).rgb;
          vec3 diff = (iColor.rgb - meanColor) * 7.07;
          diff = min(diff * diff, vec3(1.0));
          float theta = 0.1;
          float p = clamp((min(iColor.r, meanColor.r - 0.1) - 0.2) * 4.0, 0.0, 1.0);
          float meanVar = (diff.r + diff.g + diff.b) / 3.0;
          float kMin = clamp((1.0 - meanVar / (meanVar + theta)) * p * u_smooth, 0.0, 1.0);
          color = mix(iColor.rgb, meanColor, kMin);
        }

        if (u_whiten > 0.0) {
          vec3 colorEPM = color;
          color = clamp((colorEPM - vec3(levelBlack)) * levelRangeInv, 0.0, 1.0);
          vec3 texel = vec3(
            texture(u_lookupGray, vec2(color.r, 0.5)).r,
            texture(u_lookupGray, vec2(color.g, 0.5)).g,
            texture(u_lookupGray, vec2(color.b, 0.5)).b
          );
          texel = mix(color, texel, 0.5);
          texel = mix(colorEPM, texel, alpha);

          texel = clamp(texel, 0.0, 1.0);
          float blueColor = texel.b * 15.0;
          vec2 quad1;
          quad1.y = floor(floor(blueColor) * 0.25);
          quad1.x = floor(blueColor) - (quad1.y * 4.0);
          vec2 quad2;
          quad2.y = floor(ceil(blueColor) * 0.25);
          quad2.x = ceil(blueColor) - (quad2.y * 4.0);
          vec2 texPos2 = texel.rg * 0.234375 + 0.0078125;
          vec2 texPos1 = quad1 * 0.25 + texPos2;
          texPos2 = quad2 * 0.25 + texPos2;
          vec3 newColor1Origin = texture(u_lookupOrigin, texPos1).rgb;
          vec3 newColor2Origin = texture(u_lookupOrigin, texPos2).rgb;
          vec3 colorOrigin = mix(newColor1Origin, newColor2Origin, fract(blueColor));
          texel = mix(colorOrigin, color, alpha);

          texel = clamp(texel, 0.0, 1.0);
          blueColor = texel.b * 15.0;
          quad1.y = floor(floor(blueColor) * 0.25);
          quad1.x = floor(blueColor) - (quad1.y * 4.0);
          quad2.y = floor(ceil(blueColor) * 0.25);
          quad2.x = ceil(blueColor) - (quad2.y * 4.0);
          texPos2 = texel.rg * 0.234375 + 0.0078125;
          texPos1 = quad1 * 0.25 + texPos2;
          texPos2 = quad2 * 0.25 + texPos2;
          vec3 newColor1 = texture(u_lookupSkin, texPos1).rgb;
          vec3 newColor2 = texture(u_lookupSkin, texPos2).rgb;
          color = mix(newColor1, newColor2, fract(blueColor));
          color = clamp(color, 0.0, 1.0);

          float blueColorCustom = color.b * 63.0;
          vec2 quad1Custom;
          quad1Custom.y = floor(floor(blueColorCustom) / 8.0);
          quad1Custom.x = floor(blueColorCustom) - (quad1Custom.y * 8.0);
          vec2 quad2Custom;
          quad2Custom.y = floor(ceil(blueColorCustom) / 8.0);
          quad2Custom.x = ceil(blueColorCustom) - (quad2Custom.y * 8.0);
          vec2 texPos1Custom;
          texPos1Custom.x = (quad1Custom.x / 8.0) + 0.5 / 512.0 + ((1.0 / 8.0 - 1.0 / 512.0) * color.r);
          texPos1Custom.y = (quad1Custom.y / 8.0) + 0.5 / 512.0 + ((1.0 / 8.0 - 1.0 / 512.0) * color.g);
          vec2 texPos2Custom;
          texPos2Custom.x = (quad2Custom.x / 8.0) + 0.5 / 512.0 + ((1.0 / 8.0 - 1.0 / 512.0) * color.r);
          texPos2Custom.y = (quad2Custom.y / 8.0) + 0.5 / 512.0 + ((1.0 / 8.0 - 1.0 / 512.0) * color.g);
          newColor1 = texture(u_lookupCustom, texPos1Custom).rgb;
          newColor2 = texture(u_lookupCustom, texPos2Custom).rgb;
          vec3 colorCustom = mix(newColor1, newColor2, fract(blueColorCustom));
          color = mix(color, colorCustom, u_whiten);
        }

        fragColor = vec4(color, iColor.a);
      }`;
    return this.linkProgram(vsSource, fsSource);
  }

  // A 9-tap box blur (radius 4, weight 1/9 each - matching gpupixel's own
  // BoxMonoBlurFilter at its default radius), run once horizontally and
  // once vertically to make a full separable blur. u_step carries the
  // per-tap offset in UV space, computed by the caller from the source
  // dimensions so the same program serves both directions.
  private buildBlurProgram(): WebGLProgram {
    const vsSource = `#version 300 es
      const vec2 corners[4] = vec2[](vec2(-1.,-1.), vec2(1.,-1.), vec2(1.,1.), vec2(-1.,1.));
      const vec2 uvs[4] = vec2[](vec2(0.,1.), vec2(1.,1.), vec2(1.,0.), vec2(0.,0.));
      out vec2 v_uv;
      void main() {
        gl_Position = vec4(corners[gl_VertexID], 0., 1.);
        v_uv = uvs[gl_VertexID];
      }`;
    const fsSource = `#version 300 es
      precision highp float;
      uniform sampler2D u_src;
      uniform vec2 u_step;
      in vec2 v_uv;
      out vec4 fragColor;
      void main() {
        vec3 sum = vec3(0.0);
        for (int i = -4; i <= 4; i++) {
          sum += texture(u_src, v_uv + u_step * float(i)).rgb;
        }
        fragColor = vec4(sum / 9.0, 1.0);
      }`;
    return this.linkProgram(vsSource, fsSource);
  }

  private linkProgram(vsSource: string, fsSource: string): WebGLProgram {
    const gl = this.gl;
    const compile = (type: number, source: string): WebGLShader => {
      const shader = gl.createShader(type);
      if (!shader) throw new Error("shader create failed");
      gl.shaderSource(shader, source);
      gl.compileShader(shader);
      if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
        throw new Error(String(gl.getShaderInfoLog(shader)));
      }
      return shader;
    };
    const program = gl.createProgram();
    if (!program) throw new Error("program create failed");
    gl.attachShader(program, compile(gl.VERTEX_SHADER, vsSource));
    gl.attachShader(program, compile(gl.FRAGMENT_SHADER, fsSource));
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      throw new Error(String(gl.getProgramInfoLog(program)));
    }
    return program;
  }

  private createRenderTarget(): { texture: WebGLTexture; fbo: WebGLFramebuffer } {
    const gl = this.gl;
    const texture = gl.createTexture();
    if (!texture) throw new Error("texture create failed");
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    const fbo = gl.createFramebuffer();
    if (!fbo) throw new Error("framebuffer create failed");
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    return { texture, fbo };
  }

  /// (Re)allocates the two intermediate blur targets at the source frame's
  /// own resolution - the blur runs on the camera frame before it's scaled
  /// to the canvas, matching gpupixel's own filter, which blurs its input
  /// framebuffer rather than whatever size it happens to be displayed at.
  private ensureBlurTargets(width: number, height: number): void {
    if (this.meanWidth === width && this.meanHeight === height) return;
    this.meanWidth = width;
    this.meanHeight = height;
    const gl = this.gl;
    for (const texture of [this.blurTexture, this.meanTexture]) {
      gl.bindTexture(gl.TEXTURE_2D, texture);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    }
  }

  /// Two-pass separable blur of the current camera frame into meanTexture:
  /// horizontal into the intermediate blurTexture, then vertical from
  /// there. Only run when smoothing is actually active - skipped
  /// entirely otherwise, matching every other effect's no-op-when-off
  /// degradation.
  private computeMean(width: number, height: number): void {
    const gl = this.gl;
    gl.useProgram(this.blurProgram);
    gl.viewport(0, 0, width, height);

    gl.bindFramebuffer(gl.FRAMEBUFFER, this.blurFbo);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.texture);
    gl.uniform2f(this.blurStepUniform, 4 / width, 0);
    gl.drawArrays(gl.TRIANGLE_FAN, 0, 4);

    gl.bindFramebuffer(gl.FRAMEBUFFER, this.meanFbo);
    gl.bindTexture(gl.TEXTURE_2D, this.blurTexture);
    gl.uniform2f(this.blurStepUniform, 0, 4 / height);
    gl.drawArrays(gl.TRIANGLE_FAN, 0, 4);

    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  }

  /// Uploads a still image directly into the frame texture the composite
  /// shader reads, bypassing the video element entirely. Skin-smoothing's
  /// blend factor is content-adaptive (it deliberately favors flat,
  /// skin-toned regions over sharp edges - see the shader comment above),
  /// so proving it needs a real photo rather than a synthetic test
  /// pattern; freezeCamera() first stops tick() from re-uploading over it
  /// on the next frame.
  async loadStillFrame(url: string): Promise<void> {
    const bitmap = await createImageBitmap(await (await fetch(url)).blob());
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.texture);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, bitmap);
    this.frameWidth = bitmap.width;
    this.frameHeight = bitmap.height;
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
    this.core.reportFrame(this.session, frameTimeUs);

    const gl = this.gl;
    if (this.video.readyState >= 2) {
      if (this.video.currentTime !== this.lastVideoTime) {
        this.lastVideoTime = this.video.currentTime;
        this.cameraFrames += 1;
        gl.bindTexture(gl.TEXTURE_2D, this.texture);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, this.video);
        this.frameWidth = this.video.videoWidth;
        this.frameHeight = this.video.videoHeight;
      }
      this.ensureBlurTargets(this.frameWidth, this.frameHeight);
      const smoothActive = this.smoothAmount > 0;
      if (smoothActive) {
        this.computeMean(this.frameWidth, this.frameHeight);
      }

      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.viewport(0, 0, this.canvas.width, this.canvas.height);
      gl.useProgram(this.program);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, this.texture);
      gl.activeTexture(gl.TEXTURE5);
      gl.bindTexture(gl.TEXTURE_2D, this.meanTexture);
      gl.uniform1f(this.smoothUniform, smoothActive ? this.smoothAmount : 0);
      gl.uniform1f(this.whitenUniform, this.whitenAmount);
      gl.drawArrays(gl.TRIANGLE_FAN, 0, 4);
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

  readCenterPixel(): Uint8Array {
    const gl = this.gl;
    const pixel = new Uint8Array(4);
    gl.readPixels(
      Math.floor(this.canvas.width / 2),
      Math.floor(this.canvas.height / 2),
      1,
      1,
      gl.RGBA,
      gl.UNSIGNED_BYTE,
      pixel,
    );
    return pixel;
  }

  /// Sums every RGBA byte over the whole canvas - a courser but far more
  /// robust brightness/content probe than one fixed pixel, since a
  /// synthetic test pattern (Chrome's fake capture device, say) is free
  /// to put its own "lit" content anywhere and leave any single fixed
  /// coordinate dark for long stretches.
  readFrameSum(): number {
    const gl = this.gl;
    const pixels = new Uint8Array(this.canvas.width * this.canvas.height * 4);
    gl.readPixels(0, 0, this.canvas.width, this.canvas.height, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
    let sum = 0;
    for (const value of pixels) sum += value;
    return sum;
  }
}
