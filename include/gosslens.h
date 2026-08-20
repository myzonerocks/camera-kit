/*
 * Gosslens C ABI.
 *
 * This header is the one boundary between the core and every SDK. It is
 * hand-written, versioned, and frozen per minor release: within a major
 * version symbols and struct layouts are only ever appended, never changed
 * or reordered. The abi gate diffs this surface on every change.
 *
 * Conventions:
 *   - Every symbol is prefixed goss_.
 *   - Handles are opaque. Creation returns ownership; goss_*_destroy releases
 *     it. A destroy call accepts null and does nothing.
 *   - Functions that can fail return goss_status. No errno, no exceptions.
 *   - Descriptor structs are plain data with fixed layouts, documented and
 *     static-asserted byte for byte.
 *
 * Threading:
 *   - An engine and its sessions are confined to the thread that created
 *     them, called the graph thread, unless a function is marked any-thread.
 *   - goss_abi_version is any-thread and must be the first call an SDK makes;
 *     a major mismatch means the SDK must refuse to run.
 */

#ifndef GOSSLENS_H
#define GOSSLENS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GOSS_ABI_MAJOR 0u
#define GOSS_ABI_MINOR 18u
#define GOSS_ABI_VERSION ((GOSS_ABI_MAJOR << 16) | GOSS_ABI_MINOR)

/* Any-thread. Compare the high 16 bits against GOSS_ABI_MAJOR. */
uint32_t goss_abi_version(void);

/* Any-thread. Scratch allocation inside the module for embedders that
 * cannot address its memory directly, the wasm host in particular. Free
 * with the same size. */
void *goss_alloc(size_t size);
void goss_free(void *ptr, size_t size);

typedef enum goss_status {
    GOSS_OK = 0,
    GOSS_ERROR_INVALID_ARGUMENT = 1,
    GOSS_ERROR_OUT_OF_MEMORY = 2,
    GOSS_ERROR_POOL_EXHAUSTED = 3,
    GOSS_ERROR_ABI_MISMATCH = 4,
    GOSS_ERROR_RENDERER_UNAVAILABLE = 5,
    GOSS_ERROR_UNSUPPORTED = 6,
    GOSS_AGAIN = 7,
} goss_status;

typedef struct goss_engine goss_engine;
typedef struct goss_session goss_session;

/* How the pipeline is currently degraded. Levels only trade effect quality;
 * capture and preview never stop. */
typedef enum goss_degrade_level {
    GOSS_DEGRADE_FULL = 0,
    GOSS_DEGRADE_REDUCED_ML_CADENCE = 1,
    GOSS_DEGRADE_SEGMENTATION_OFF = 2,
    GOSS_DEGRADE_BEAUTY_SIMPLIFIED = 3,
    GOSS_DEGRADE_PASSTHROUGH = 4,
} goss_degrade_level;

/* Platform thermal pressure, fed by the SDK from the OS thermal API. */
typedef enum goss_thermal {
    GOSS_THERMAL_NOMINAL = 0,
    GOSS_THERMAL_FAIR = 1,
    GOSS_THERMAL_SERIOUS = 2,
    GOSS_THERMAL_CRITICAL = 3,
} goss_thermal;

/* Pixel layout of a camera frame as delivered by the platform. */
typedef enum goss_pixel_format {
    GOSS_PIXEL_NV12 = 0,
    GOSS_PIXEL_NV21 = 1,
    GOSS_PIXEL_I420 = 2,
    GOSS_PIXEL_BGRA8 = 3,
    GOSS_PIXEL_RGBA8 = 4,
} goss_pixel_format;

typedef enum goss_color_standard {
    GOSS_COLOR_BT601 = 0,
    GOSS_COLOR_BT709 = 1,
    GOSS_COLOR_BT2020 = 2,
} goss_color_standard;

typedef enum goss_color_range {
    GOSS_COLOR_RANGE_VIDEO = 0,
    GOSS_COLOR_RANGE_FULL = 1,
} goss_color_range;

/* goss_frame_desc.flags bits. Rotation is the quarter-turn count to apply for
 * upright display; mirror flips horizontally, for front cameras. */
#define GOSS_FRAME_FLAG_MIRROR 0x1u
#define GOSS_FRAME_ROTATION_SHIFT 8u
#define GOSS_FRAME_ROTATION_MASK 0x300u

/* Describes one camera frame. The pixel data itself stays in the platform
 * buffer the SDK hands over; the core never copies it on the frame path.
 * Layout: 32 bytes, static-asserted below. */
typedef struct goss_frame_desc {
    uint32_t width;
    uint32_t height;
    uint32_t pixel_format;   /* goss_pixel_format */
    uint32_t color_standard; /* goss_color_standard */
    uint32_t color_range;    /* goss_color_range */
    uint32_t flags;          /* GOSS_FRAME_* bits */
    int64_t timestamp_us;    /* capture time, monotonic microseconds */
} goss_frame_desc;

/* The render surface an SDK hands the engine: an NSWindow, CAMetalLayer,
 * ANativeWindow, or canvas handle per platform. Layout: 16 bytes on 64-bit
 * targets, 12 on wasm32. */
typedef struct goss_renderer_desc {
    void *native_window_handle;
    uint32_t width;
    uint32_t height;
} goss_renderer_desc;

/* Zero-copy plane handles for one frame: platform texture objects
 * (MTLTexture, AHardwareBuffer-backed images, WebGL textures) as opaque
 * pointer-sized values. The platform object must stay valid until the next
 * submitted frame has rendered; the SDK guarantees that by holding the
 * buffer. Layout: 32 bytes. */
typedef struct goss_frame_planes {
    uint32_t plane_count;
    uint32_t reserved; /* zero */
    uint64_t planes[3];
} goss_frame_planes;

/* A tracking result crossing the boundary. Points are x, y, z triples in
 * normalized image space; the memory belongs to the producer and stays
 * valid only for the duration of the callback or call it is passed to.
 * Layout: 24 bytes, static-asserted below. */
typedef struct goss_landmarks {
    const float *points; /* point_count * 3 floats */
    uint32_t point_count;
    float confidence;
    int64_t timestamp_us;
} goss_landmarks;

/* One face tracking result. Landmarks are x, y in frame pixels with z in
 * the same scale, three floats per point; a zero landmark_count means the
 * frame held no face. blendshapes are 52 scores in zero to one. Layout:
 * 5968 bytes, static-asserted below. */
#define GOSS_FACE_LANDMARK_COUNT 478u
#define GOSS_FACE_BLENDSHAPE_COUNT 52u
typedef struct goss_face_result {
    uint64_t frame_serial;
    int64_t timestamp_us;
    float presence;
    uint32_t landmark_count;
    float landmarks[GOSS_FACE_LANDMARK_COUNT * 3];
    float blendshapes[GOSS_FACE_BLENDSHAPE_COUNT];
} goss_face_result;

/* Canned gesture classes, in the classifier's own label order. Zero is
 * the no-gesture class, also reported when no gesture model is loaded. */
#define GOSS_GESTURE_NONE 0u
#define GOSS_GESTURE_CLOSED_FIST 1u
#define GOSS_GESTURE_OPEN_PALM 2u
#define GOSS_GESTURE_POINTING_UP 3u
#define GOSS_GESTURE_THUMB_DOWN 4u
#define GOSS_GESTURE_THUMB_UP 5u
#define GOSS_GESTURE_VICTORY 6u
#define GOSS_GESTURE_ILOVEYOU 7u

/* One tracked hand. handedness is the model's score that this is a right
 * hand; gesture is a GOSS_GESTURE_* class with its score; landmarks are
 * x, y in frame pixels with z in the same scale, three floats per point. */
#define GOSS_HAND_LANDMARK_COUNT 21u
#define GOSS_HAND_MAX 2u
typedef struct goss_hand {
    float presence;
    float handedness;
    uint32_t gesture;
    float gesture_score;
    float landmarks[GOSS_HAND_LANDMARK_COUNT * 3];
} goss_hand;

/* One hand tracking result. A zero hand_count means the frame held no
 * hands; hands beyond hand_count are zeroed. Layout: 560 bytes,
 * static-asserted below. */
typedef struct goss_hand_result {
    uint64_t frame_serial;
    int64_t timestamp_us;
    uint32_t hand_count;
    uint32_t reserved;
    goss_hand hands[GOSS_HAND_MAX];
} goss_hand_result;

/* One pose tracking result: a 33-point skeleton in frame pixels with z
 * in the same scale, plus zero-to-one visibility and presence scores per
 * point. A zero landmark_count means the frame held no body. Layout:
 * 688 bytes including tail padding, static-asserted below. */
#define GOSS_POSE_LANDMARK_COUNT 33u
typedef struct goss_pose_result {
    uint64_t frame_serial;
    int64_t timestamp_us;
    float presence;
    uint32_t landmark_count;
    float landmarks[GOSS_POSE_LANDMARK_COUNT * 3];
    float visibilities[GOSS_POSE_LANDMARK_COUNT];
    float presences[GOSS_POSE_LANDMARK_COUNT];
} goss_pose_result;

/* The live signals goss_session_tick_lens evaluates a lens's compiled
 * triggers against (a GLF `when` expression's signal reads). blendshapes
 * mirrors goss_face_result's own inline-array convention rather than a
 * pointer, so a caller already holding a face result can pass its
 * blendshapes straight through; has_face false means every face-driven
 * signal (present, and any blendshape) reads as false regardless of
 * what blendshapes holds. Layout: 232 bytes, static-asserted below. */
typedef struct goss_lens_signals {
    bool has_face;
    bool hands_present;
    bool tap;
    uint8_t reserved;
    double world_tracking_state;
    double audio_level;
    float blendshapes[GOSS_FACE_BLENDSHAPE_COUNT];
} goss_lens_signals;

/* Bounds for the engine's frame-path pools. Zero means the built-in
 * default. Layout: 8 bytes. */
typedef struct goss_engine_config {
    uint32_t texture_pool_capacity;
    uint32_t staging_pool_capacity;
} goss_engine_config;

/* Per-session pipeline configuration. frame_budget_us is the whole-pipeline
 * frame time the degradation policy holds the session to; zero means the
 * built-in default of 33333, a 30 fps budget. Layout: 8 bytes. */
typedef struct goss_session_config {
    uint32_t frame_budget_us;
    uint32_t reserved; /* zero */
} goss_session_config;

/* Graph thread. config may be null for defaults. */
goss_status goss_engine_create(const goss_engine_config *config, goss_engine **out_engine);
void goss_engine_destroy(goss_engine *engine);

/* Graph thread. Brings up the render backend on the given surface. */
goss_status goss_engine_init_renderer(goss_engine *engine, const goss_renderer_desc *desc);

/* Graph thread. Resizes the render surface. */
void goss_engine_resize(goss_engine *engine, uint32_t width, uint32_t height);

/* Graph thread. Draws the session's most recent frame to the surface and
 * presents. A null session presents the clear color. */
goss_status goss_engine_render_frame(goss_engine *engine, goss_session *session);

/* Graph thread. Requests a screenshot of the next presented frame,
 * written as path (path_len bytes, not necessarily nul-terminated) plus
 * a ".tga" suffix the renderer's own callback appends. Debug/test
 * tooling only - conformance harnesses, never a user-facing control. */
goss_status goss_engine_request_screenshot(goss_engine *engine, const uint8_t *path, size_t path_len);

/* Graph thread. Renders and presents like goss_engine_render_frame, and
 * also reads the composited output back into out_data as RGBA8 (row 0
 * first), reporting the real image size through out_width/out_height.
 * out_data must already be at least render_surface_width *
 * render_surface_height * 4 bytes (the same dimensions passed to
 * goss_engine_init_renderer, or the most recent goss_engine_resize) - the
 * call fails with invalid_argument rather than truncating silently if
 * out_capacity is smaller. Debug/test tooling only, for render backends
 * with no synchronous pixel-readback API of their own. On the WebGPU
 * backend this issues two internal frame submits (see
 * third_party/bgfx/patches/0003-webgpu-readtexture-wait-any.patch for
 * the wait-mode fix this also depends on) since bgfx's own read-texture
 * command only runs on the frame after the one that queues it. */
goss_status goss_engine_capture_frame(goss_engine *engine, goss_session *session, uint8_t *out_data, size_t out_capacity, uint32_t *out_width, uint32_t *out_height);

/* Captures the composited frame and encodes it as a PNG into out_data.
 * out_len always receives the encoded size, so a too-small buffer
 * (invalid_argument) tells the caller exactly what to retry with. The
 * encoding is deterministic: the same pixels, the same bytes. */
goss_status goss_engine_capture_photo(goss_engine *engine, goss_session *session, uint8_t *out_data, size_t out_capacity, size_t *out_len, uint32_t *out_width, uint32_t *out_height);

/* Captures the composited frame as a platform photo (1 = JPEG,
 * 2 = HEIC) at quality percent; out_len always receives the needed
 * size. Lossy and not bit-stable across runs - capture_photo stays
 * the deterministic PNG surface. UNSUPPORTED without a backend. */
goss_status goss_engine_capture_photo_as(goss_engine *engine, goss_session *session, uint32_t format, uint32_t quality, uint8_t *out_data, size_t out_capacity, size_t *out_len, uint32_t *out_width, uint32_t *out_height);

typedef struct goss_recording_config {
  uint32_t width;       /* 0 picks the renderer's output size (rounded to even) */
  uint32_t height;
  uint32_t bitrate_bps; /* 0 lets the backend pick a rate for the size */
  uint32_t codec;       /* 0 = H.264, 1 = HEVC */
} goss_recording_config;

/* Starts recording the session's rendered frames, effects baked in,
 * into the file at path. One recording per engine; every subsequent
 * goss_engine_render_frame of this session appends one video frame at
 * the frame's own timestamp until goss_engine_recording_stop. Returns
 * GOSS_ERROR_UNSUPPORTED where no recording backend exists yet. */
goss_status goss_engine_recording_start(goss_engine *engine, goss_session *session, const uint8_t *path, size_t path_len, const goss_recording_config *config);

/* Stops the engine's recording, flushing frames still in flight and
 * finalizing the container. */
goss_status goss_engine_recording_stop(goss_engine *engine);

/* Feeds interleaved f32 PCM into the session: the engine's own level
 * and beat analysis always consumes it (driving the audio.level and
 * audio.beat trigger signals), and an active recording of this session
 * muxes it as the audio track where the backend supports audio. */
goss_status goss_session_submit_audio(goss_session *session, const float *samples, uint32_t frame_count, uint32_t sample_rate, uint32_t channels, int64_t timestamp_us);

typedef struct goss_world_state {
    uint32_t tracking_state; /* 0 unavailable, 1 initializing, 2 tracking, 3 limited */
    float world_from_camera[16]; /* column-major camera pose in world space */
    float projection[16];        /* the platform camera's real projection */
    int64_t timestamp_us;
} goss_world_state;

typedef struct goss_world_plane {
    uint64_t id;
    float pose[16];
    float extent_x;
    float extent_z;
    uint32_t classification; /* 0 other, 1 floor, 2 wall, 3 ceiling, 4 table */
} goss_world_plane;

typedef struct goss_world_anchor {
    uint64_t id;
    float pose[16];
} goss_world_anchor;

typedef struct goss_world_light {
    float ambient_intensity;
    float color_temperature_kelvin;
} goss_world_light;

/* Feeds the platform's world understanding into the session: camera
 * pose and projection, tracked planes, anchors, and the light
 * estimate, once per platform frame. Drives the world.tracking_state
 * trigger signal and world-anchored lens content. */
goss_status goss_session_submit_world(goss_session *session, const goss_world_state *state, const goss_world_plane *planes, size_t plane_count, const goss_world_anchor *anchors, size_t anchor_count, const goss_world_light *light);

typedef struct goss_capture_config {
  uint32_t width;       /* 0 = the submitted frame's own resolution */
  uint32_t height;
  uint32_t supersample; /* reserved; 0 or 1 is 1:1 today */
  uint32_t format;      /* 0 = PNG, 1 = JPEG, 2 = HEIC */
  uint32_t quality;     /* 1..100 for lossy formats, 0 = backend default */
} goss_capture_config;

/* Composites the still at the configured resolution - the submitted
 * frame's own size when width and height are zero - independent of the
 * preview swap chain, and encodes it. out_len always receives the
 * encoded size. PNG has no size ceiling; JPEG/HEIC need the platform
 * photo backend. */
goss_status goss_engine_capture_still(goss_engine *engine, goss_session *session, const goss_capture_config *config, uint8_t *out_data, size_t out_capacity, size_t *out_len, uint32_t *out_width, uint32_t *out_height);

/* Graph thread. config may be null for defaults. */
goss_status goss_session_create(goss_engine *engine, const goss_session_config *config, goss_session **out_session);
void goss_session_destroy(goss_session *session);

/* Graph thread. Hands over one camera frame, zero-copy. The descriptor is
 * copied; the plane handles are wrapped, not read, and their platform
 * objects must outlive the next rendered frame. */
goss_status goss_session_submit_frame(goss_session *session, const goss_frame_desc *desc, const goss_frame_planes *planes);

/* Any-thread, pure. Writes the YCbCr to RGB conversion for a standard and
 * range as one column-major homogeneous matrix: rgb = (m * vec4(yuv, 1)).
 * out_matrix holds 16 floats. */
goss_status goss_color_yuv_to_rgb(uint32_t color_standard, uint32_t color_range, float *out_matrix);

/* Graph thread. The stated CPU path: copies NV12 planes into pooled
 * textures for SDKs whose zero-copy import is not wired yet. The copy is
 * counted; prefer goss_session_submit_frame. */
goss_status goss_session_submit_frame_copy(goss_session *session, const goss_frame_desc *desc, const uint8_t *y, uint32_t y_stride, const uint8_t *uv, uint32_t uv_stride);

/* Graph thread. Zero-copy submission of a platform hardware buffer
 * (AHardwareBuffer). Any status other than GOSS_OK means this stream falls
 * back to goss_session_submit_frame_copy. */
goss_status goss_session_submit_hardware_buffer(goss_session *session, const goss_frame_desc *desc, void *hardware_buffer);

/* Graph thread. Reports one finished frame: measured whole-pipeline time
 * plus current thermal pressure. Returns the degradation level in effect
 * for the next frame. */
goss_degrade_level goss_session_report_frame(goss_session *session, uint32_t frame_time_us, goss_thermal thermal);

/* Graph thread. The level currently in effect. */
goss_degrade_level goss_session_degrade_level(const goss_session *session);

/* Graph thread. Stands the face tracking worker up from a model bundle
 * (a MediaPipe .task file). The bundle bytes are copied; the caller may
 * release them on return. Builds without the inference stack report
 * unsupported. */
goss_status goss_session_enable_face_tracking(goss_session *session, const uint8_t *task_bytes, size_t task_len, int32_t threads);
void goss_session_disable_face_tracking(goss_session *session);

/* Graph thread. Stands the hand tracking worker up from a model bundle:
 * a hand landmarker .task, or a gesture recognizer .task whose nested
 * gesture models additionally score each hand's canned gesture. The
 * bundle bytes are copied; the caller may release them on return.
 * Builds without the inference stack report unsupported. */
goss_status goss_session_enable_hand_tracking(goss_session *session, const uint8_t *task_bytes, size_t task_len, int32_t threads);
void goss_session_disable_hand_tracking(goss_session *session);

/* Graph thread. Stands the pose tracking worker up from a model bundle
 * (a MediaPipe pose landmarker .task file). The bundle bytes are copied;
 * the caller may release them on return. Builds without the inference
 * stack report unsupported. */
goss_status goss_session_enable_pose_tracking(goss_session *session, const uint8_t *task_bytes, size_t task_len, int32_t threads);
void goss_session_disable_pose_tracking(goss_session *session);

/* Graph thread. Stands the segmentation worker up from a raw model
 * (a selfie or hair segmenter .tflite file, not bundled the way
 * face_landmarker.task is). The model bytes are copied; the caller may
 * release them on return. Builds without the inference stack report
 * unsupported. */
goss_status goss_session_enable_segmentation(goss_session *session, const uint8_t *model_bytes, size_t model_len, int32_t threads);
void goss_session_disable_segmentation(goss_session *session);

/* Graph thread. Feeds one NV12 frame to the tracking worker. The planes
 * are CPU addresses valid for the duration of the call; the worker copies
 * and returns immediately, dropping stale frames in favor of this one.
 * Feeds the segmentation worker the same frame if it is enabled too. */
goss_status goss_session_track_frame(goss_session *session, const goss_frame_desc *desc, const uint8_t *y, uint32_t y_stride, const uint8_t *uv, uint32_t uv_stride);

/* Graph thread. Reads the newest tracking result into caller memory.
 * Reports GOSS_AGAIN until the worker has published its first result. */
goss_status goss_session_face_result(goss_session *session, goss_face_result *out_result);

/* Graph thread. Reads the newest hand tracking result into caller
 * memory. Reports GOSS_AGAIN until the worker has published its first
 * result. */
goss_status goss_session_hand_result(goss_session *session, goss_hand_result *out_result);

/* Graph thread. Reads the newest pose tracking result into caller
 * memory. Reports GOSS_AGAIN until the worker has published its first
 * result. */
goss_status goss_session_pose_result(goss_session *session, goss_pose_result *out_result);

/* Graph thread. Fits the canonical face onto the newest tracked
 * landmarks and writes the head transform - canonical metric space
 * (centimeters) into frame pixels - as a column-major 4x4. Reports
 * GOSS_AGAIN until a face is tracked or while the fit is degenerate. */
goss_status goss_session_face_pose(goss_session *session, float *out_matrix);

/* Effect identifiers for goss_session_set_beauty. Values clamp to zero and
 * one; zero disables the effect. */
#define GOSS_BEAUTY_SMOOTH 0
#define GOSS_BEAUTY_WHITEN 1
#define GOSS_BEAUTY_THIN_FACE 2
#define GOSS_BEAUTY_BIG_EYE 3
#define GOSS_BEAUTY_LIPSTICK 4
#define GOSS_BEAUTY_BLUSH 5

/* Graph thread. Stands the beauty chain up for a session. resource_path
 * names the directory holding the effect engine's shader and image
 * assets. Builds without the effects engine report unsupported. */
goss_status goss_session_enable_beauty(goss_session *session, const char *resource_path);
void goss_session_disable_beauty(goss_session *session);

/* Graph thread. Sets one beauty effect's strength; see the GOSS_BEAUTY_*
 * identifiers above. Reports GOSS_AGAIN until beauty is enabled. */
goss_status goss_session_set_beauty(goss_session *session, int32_t effect, float value);

/* Graph thread, web only. Uploads one of whiten's four lookup textures -
 * slot 0 gray, 1 origin, 2 skin, 3 custom. rgba is a caller-decoded
 * image; whiten stays inert until all four slots are loaded. Reports
 * GOSS_UNSUPPORTED on every other target, where whiten runs through the
 * native beauty engine instead. */
goss_status goss_session_set_beauty_lut(goss_session *session, int32_t slot, const uint8_t *rgba, uint32_t width, uint32_t height);

/* Graph thread, web only. Uploads lipstick's (GOSS_BEAUTY_LIPSTICK) or
 * blush's (GOSS_BEAUTY_BLUSH) own source image - caller-decoded the same
 * way goss_session_set_beauty_lut's rgba is. Reports GOSS_UNSUPPORTED on
 * every other target. */
goss_status goss_session_set_beauty_makeup_texture(goss_session *session, int32_t effect, const uint8_t *rgba, uint32_t width, uint32_t height);

/* Graph thread, web only. Feeds one frame's tracked face landmarks into
 * a session directly - there is no internal tracking worker to drive
 * GOSS_BEAUTY_THIN_FACE/GOSS_BEAUTY_BIG_EYE/GOSS_BEAUTY_LIPSTICK/GOSS_BEAUTY_BLUSH
 * on web (goss_session_enable_face_tracking reports GOSS_ERROR_UNSUPPORTED
 * there); the caller runs its own tracker and hands the result straight
 * in. points holds point_count * 3 floats (x, y in frame pixels, z in
 * the same scale, matching goss_face_result's own landmarks convention);
 * point_count must be GOSS_FACE_LANDMARK_COUNT, or zero to clear any
 * previously set landmarks (no face this frame). Reports GOSS_UNSUPPORTED
 * on every other target, where goss_session_track_frame feeds the same
 * effects instead. */
goss_status goss_session_set_face_landmarks(goss_session *session, const float *points, uint32_t point_count);

/* Graph thread. The CPU-copy path for a single-plane BGRA8/RGBA8 frame -
 * a canvas or video element's own byte buffer, with no native GPU handle
 * behind it the way goss_session_submit_frame's zero-copy path needs. Same
 * shape as goss_session_submit_frame_copy, one interleaved plane instead
 * of NV12's two. */
goss_status goss_session_submit_frame_rgba_copy(goss_session *session, const goss_frame_desc *desc, const uint8_t *rgba, uint32_t stride);

/* Graph thread. Runs the beauty chain over one RGBA frame on the calling
 * thread, reading the newest tracking result for the landmark driven
 * effects when face tracking is enabled. The stated CPU path; live
 * preview integration on the render thread is the device side of this
 * row. */
goss_status goss_session_beautify_frame(goss_session *session, const uint8_t *rgba_in, uint32_t width, uint32_t height, uint8_t *rgba_out);

/* Graph thread. Replaces any currently active lens (unsplicing it first)
 * with the one manifest_json describes, splices its node subgraph into
 * the session's frame graph, and applies its default effect values to
 * the beauty chain if one is enabled. The bytes are copied; the caller
 * may release them on return. A manifest that fails to parse, or that
 * names a node type this build does not support, activates nothing and
 * reports GOSS_INVALID_ARGUMENT. */
goss_status goss_session_activate_lens(goss_session *session, const uint8_t *manifest_json, size_t manifest_len);

/* Graph thread. Same activation goss_session_activate_lens performs, from
 * bundle_path/manifest.json, plus one further step that function cannot
 * do without a bundle path to read from: a bgfx program is created for
 * every shader.pass node the lens splices, loading whichever compiled
 * variant under bundle_path/shaders/ matches the running platform's
 * active graphics backend. A shader failing to load leaves that one
 * pass without a program rather than failing the whole activation - a
 * packaged bundle was already proven to compile by the validator, so a
 * load failure here is a runtime anomaly, not an authoring error. */
goss_status goss_session_activate_lens_from_directory(goss_session *session, const uint8_t *bundle_path, size_t bundle_path_len);

/* Graph thread. Unsplices the active lens and frees everything its
 * activation allocated. Accepts no active lens and does nothing. */
void goss_session_deactivate_lens(goss_session *session);

/* Graph thread. Advances the active lens by dt_us of real time,
 * evaluating its compiled triggers against signals and applying every
 * effect value that changed as a result to the beauty chain, if one is
 * enabled. Reports GOSS_AGAIN with no active lens. */
goss_status goss_session_tick_lens(goss_session *session, uint32_t dt_us, const goss_lens_signals *signals);

/* Graph thread. Reads a live parameter of the active lens by name,
 * including whatever a script node last wrote, into out_value. Reports
 * GOSS_AGAIN with no active lens and GOSS_INVALID_ARGUMENT for an unknown
 * name. */
goss_status goss_session_parameter_value(goss_session *session, const uint8_t *name, size_t name_len, float *out_value);

#if !defined(__cplusplus) && (__STDC_VERSION__ >= 201112L)
_Static_assert(sizeof(goss_frame_desc) == 32, "goss_frame_desc layout is frozen");
_Static_assert(sizeof(goss_landmarks) == 24, "goss_landmarks layout is frozen");
_Static_assert(sizeof(goss_engine_config) == 8, "goss_engine_config layout is frozen");
_Static_assert(sizeof(goss_session_config) == 8, "goss_session_config layout is frozen");
_Static_assert(sizeof(goss_face_result) == 5968, "goss_face_result layout is frozen");
_Static_assert(offsetof(goss_face_result, landmarks) == 24, "goss_face_result layout is frozen");
_Static_assert(sizeof(goss_hand) == 268, "goss_hand layout is frozen");
_Static_assert(sizeof(goss_hand_result) == 560, "goss_hand_result layout is frozen");
_Static_assert(offsetof(goss_hand_result, hands) == 24, "goss_hand_result layout is frozen");
_Static_assert(sizeof(goss_pose_result) == 688, "goss_pose_result layout is frozen");
_Static_assert(offsetof(goss_pose_result, landmarks) == 24, "goss_pose_result layout is frozen");
_Static_assert(sizeof(goss_renderer_desc) == (sizeof(void *) == 8 ? 16 : 12), "goss_renderer_desc layout is frozen");
_Static_assert(sizeof(goss_frame_planes) == 32, "goss_frame_planes layout is frozen");
_Static_assert(sizeof(goss_lens_signals) == 232, "goss_lens_signals layout is frozen");
_Static_assert(offsetof(goss_lens_signals, world_tracking_state) == 8, "goss_lens_signals layout is frozen");
_Static_assert(offsetof(goss_lens_signals, blendshapes) == 24, "goss_lens_signals layout is frozen");
#endif

#ifdef __cplusplus
}
#endif

#endif /* GOSSLENS_H */
