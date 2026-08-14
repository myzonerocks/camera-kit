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
export class PreviewSession {
  private stream: MediaStream | null = null;
  private video = document.createElement("video");
  private gl: WebGL2RenderingContext;
  private program: WebGLProgram;
  private texture: WebGLTexture;
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
    const gl = canvas.getContext("webgl2");
    if (!gl) throw new Error("webgl2 unavailable");
    this.gl = gl;
    this.program = this.buildProgram();
    const texture = gl.createTexture();
    if (!texture) throw new Error("texture create failed");
    this.texture = texture;
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  }

  private setState(state: CaptureState): void {
    this.state = state;
    this.events.onState?.(state);
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
    const fsSource = `#version 300 es
      precision mediump float;
      uniform sampler2D u_frame;
      in vec2 v_uv;
      out vec4 fragColor;
      void main() { fragColor = texture(u_frame, v_uv); }`;
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
      }
      gl.viewport(0, 0, this.canvas.width, this.canvas.height);
      gl.useProgram(this.program);
      gl.bindTexture(gl.TEXTURE_2D, this.texture);
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
}
