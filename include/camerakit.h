/*
 * Camera Kit C ABI.
 *
 * This header is the one boundary between the core and every shell. It is
 * hand-written, versioned, and frozen per minor release: within a major
 * version symbols and struct layouts are only ever appended, never changed
 * or reordered. The abi gate diffs this surface on every change.
 *
 * Conventions:
 *   - Every symbol is prefixed ck_.
 *   - Handles are opaque. Creation returns ownership; ck_*_destroy releases
 *     it. A destroy call accepts null and does nothing.
 *   - Functions that can fail return ck_status. No errno, no exceptions.
 *   - Descriptor structs are plain data with fixed layouts, documented and
 *     static-asserted byte for byte.
 *
 * Threading:
 *   - An engine and its sessions are confined to the thread that created
 *     them, called the graph thread, unless a function is marked any-thread.
 *   - ck_abi_version is any-thread and must be the first call a shell makes;
 *     a major mismatch means the shell must refuse to run.
 */

#ifndef CAMERAKIT_H
#define CAMERAKIT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CK_ABI_MAJOR 0u
#define CK_ABI_MINOR 8u
#define CK_ABI_VERSION ((CK_ABI_MAJOR << 16) | CK_ABI_MINOR)

/* Any-thread. Compare the high 16 bits against CK_ABI_MAJOR. */
uint32_t ck_abi_version(void);

/* Any-thread. Scratch allocation inside the module for embedders that
 * cannot address its memory directly, the wasm host in particular. Free
 * with the same size. */
void *ck_alloc(size_t size);
void ck_free(void *ptr, size_t size);

typedef enum ck_status {
    CK_OK = 0,
    CK_ERROR_INVALID_ARGUMENT = 1,
    CK_ERROR_OUT_OF_MEMORY = 2,
    CK_ERROR_POOL_EXHAUSTED = 3,
    CK_ERROR_ABI_MISMATCH = 4,
    CK_ERROR_RENDERER_UNAVAILABLE = 5,
    CK_ERROR_UNSUPPORTED = 6,
    CK_AGAIN = 7,
} ck_status;

typedef struct ck_engine ck_engine;
typedef struct ck_session ck_session;

/* How the pipeline is currently degraded. Levels only trade effect quality;
 * capture and preview never stop. */
typedef enum ck_degrade_level {
    CK_DEGRADE_FULL = 0,
    CK_DEGRADE_REDUCED_ML_CADENCE = 1,
    CK_DEGRADE_SEGMENTATION_OFF = 2,
    CK_DEGRADE_BEAUTY_SIMPLIFIED = 3,
    CK_DEGRADE_PASSTHROUGH = 4,
} ck_degrade_level;

/* Platform thermal pressure, fed by the shell from the OS thermal API. */
typedef enum ck_thermal {
    CK_THERMAL_NOMINAL = 0,
    CK_THERMAL_FAIR = 1,
    CK_THERMAL_SERIOUS = 2,
    CK_THERMAL_CRITICAL = 3,
} ck_thermal;

/* Pixel layout of a camera frame as delivered by the platform. */
typedef enum ck_pixel_format {
    CK_PIXEL_NV12 = 0,
    CK_PIXEL_NV21 = 1,
    CK_PIXEL_I420 = 2,
    CK_PIXEL_BGRA8 = 3,
    CK_PIXEL_RGBA8 = 4,
} ck_pixel_format;

typedef enum ck_color_standard {
    CK_COLOR_BT601 = 0,
    CK_COLOR_BT709 = 1,
    CK_COLOR_BT2020 = 2,
} ck_color_standard;

typedef enum ck_color_range {
    CK_COLOR_RANGE_VIDEO = 0,
    CK_COLOR_RANGE_FULL = 1,
} ck_color_range;

/* ck_frame_desc.flags bits. Rotation is the quarter-turn count to apply for
 * upright display; mirror flips horizontally, for front cameras. */
#define CK_FRAME_FLAG_MIRROR 0x1u
#define CK_FRAME_ROTATION_SHIFT 8u
#define CK_FRAME_ROTATION_MASK 0x300u

/* Describes one camera frame. The pixel data itself stays in the platform
 * buffer the shell hands over; the core never copies it on the frame path.
 * Layout: 32 bytes, static-asserted below. */
typedef struct ck_frame_desc {
    uint32_t width;
    uint32_t height;
    uint32_t pixel_format;   /* ck_pixel_format */
    uint32_t color_standard; /* ck_color_standard */
    uint32_t color_range;    /* ck_color_range */
    uint32_t flags;          /* CK_FRAME_* bits */
    int64_t timestamp_us;    /* capture time, monotonic microseconds */
} ck_frame_desc;

/* The render surface a shell hands the engine: an NSWindow, CAMetalLayer,
 * ANativeWindow, or canvas handle per platform. Layout: 16 bytes on 64-bit
 * targets, 12 on wasm32. */
typedef struct ck_renderer_desc {
    void *native_window_handle;
    uint32_t width;
    uint32_t height;
} ck_renderer_desc;

/* Zero-copy plane handles for one frame: platform texture objects
 * (MTLTexture, AHardwareBuffer-backed images, WebGL textures) as opaque
 * pointer-sized values. The platform object must stay valid until the next
 * submitted frame has rendered; the shell guarantees that by holding the
 * buffer. Layout: 32 bytes. */
typedef struct ck_frame_planes {
    uint32_t plane_count;
    uint32_t reserved; /* zero */
    uint64_t planes[3];
} ck_frame_planes;

/* A tracking result crossing the boundary. Points are x, y, z triples in
 * normalized image space; the memory belongs to the producer and stays
 * valid only for the duration of the callback or call it is passed to.
 * Layout: 24 bytes, static-asserted below. */
typedef struct ck_landmarks {
    const float *points; /* point_count * 3 floats */
    uint32_t point_count;
    float confidence;
    int64_t timestamp_us;
} ck_landmarks;

/* One face tracking result. Landmarks are x, y in frame pixels with z in
 * the same scale, three floats per point; a zero landmark_count means the
 * frame held no face. blendshapes are 52 scores in zero to one. Layout:
 * 5968 bytes, static-asserted below. */
#define CK_FACE_LANDMARK_COUNT 478u
#define CK_FACE_BLENDSHAPE_COUNT 52u
typedef struct ck_face_result {
    uint64_t frame_serial;
    int64_t timestamp_us;
    float presence;
    uint32_t landmark_count;
    float landmarks[CK_FACE_LANDMARK_COUNT * 3];
    float blendshapes[CK_FACE_BLENDSHAPE_COUNT];
} ck_face_result;

/* The live signals ck_session_tick_lens evaluates a lens's compiled
 * triggers against (a GLF `when` expression's signal reads). blendshapes
 * mirrors ck_face_result's own inline-array convention rather than a
 * pointer, so a caller already holding a face result can pass its
 * blendshapes straight through; has_face false means every face-driven
 * signal (present, and any blendshape) reads as false regardless of
 * what blendshapes holds. Layout: 232 bytes, static-asserted below. */
typedef struct ck_lens_signals {
    bool has_face;
    bool hands_present;
    bool tap;
    uint8_t reserved;
    double world_tracking_state;
    double audio_level;
    float blendshapes[CK_FACE_BLENDSHAPE_COUNT];
} ck_lens_signals;

/* Bounds for the engine's frame-path pools. Zero means the built-in
 * default. Layout: 8 bytes. */
typedef struct ck_engine_config {
    uint32_t texture_pool_capacity;
    uint32_t staging_pool_capacity;
} ck_engine_config;

/* Per-session pipeline configuration. frame_budget_us is the whole-pipeline
 * frame time the degradation policy holds the session to; zero means the
 * built-in default of 33333, a 30 fps budget. Layout: 8 bytes. */
typedef struct ck_session_config {
    uint32_t frame_budget_us;
    uint32_t reserved; /* zero */
} ck_session_config;

/* Graph thread. config may be null for defaults. */
ck_status ck_engine_create(const ck_engine_config *config, ck_engine **out_engine);
void ck_engine_destroy(ck_engine *engine);

/* Graph thread. Brings up the render backend on the given surface. */
ck_status ck_engine_init_renderer(ck_engine *engine, const ck_renderer_desc *desc);

/* Graph thread. Resizes the render surface. */
void ck_engine_resize(ck_engine *engine, uint32_t width, uint32_t height);

/* Graph thread. Draws the session's most recent frame to the surface and
 * presents. A null session presents the clear color. */
ck_status ck_engine_render_frame(ck_engine *engine, ck_session *session);

/* Graph thread. Requests a screenshot of the next presented frame,
 * written as path (path_len bytes, not necessarily nul-terminated) plus
 * a ".tga" suffix the renderer's own callback appends. Debug/test
 * tooling only - conformance harnesses, never a user-facing control. */
ck_status ck_engine_request_screenshot(ck_engine *engine, const uint8_t *path, size_t path_len);

/* Graph thread. Renders and presents like ck_engine_render_frame, and
 * also reads the composited output back into out_data as RGBA8 (row 0
 * first), reporting the real image size through out_width/out_height.
 * out_data must already be at least render_surface_width *
 * render_surface_height * 4 bytes (the same dimensions passed to
 * ck_engine_init_renderer, or the most recent ck_engine_resize) - the
 * call fails with invalid_argument rather than truncating silently if
 * out_capacity is smaller. Debug/test tooling only, for render backends
 * with no synchronous pixel-readback API of their own. On the WebGPU
 * backend this issues two internal frame submits (see
 * third_party/bgfx/patches/0003-webgpu-readtexture-wait-any.patch for
 * the wait-mode fix this also depends on) since bgfx's own read-texture
 * command only runs on the frame after the one that queues it. */
ck_status ck_engine_capture_frame(ck_engine *engine, ck_session *session, uint8_t *out_data, size_t out_capacity, uint32_t *out_width, uint32_t *out_height);

/* Graph thread. config may be null for defaults. */
ck_status ck_session_create(ck_engine *engine, const ck_session_config *config, ck_session **out_session);
void ck_session_destroy(ck_session *session);

/* Graph thread. Hands over one camera frame, zero-copy. The descriptor is
 * copied; the plane handles are wrapped, not read, and their platform
 * objects must outlive the next rendered frame. */
ck_status ck_session_submit_frame(ck_session *session, const ck_frame_desc *desc, const ck_frame_planes *planes);

/* Any-thread, pure. Writes the YCbCr to RGB conversion for a standard and
 * range as one column-major homogeneous matrix: rgb = (m * vec4(yuv, 1)).
 * out_matrix holds 16 floats. */
ck_status ck_color_yuv_to_rgb(uint32_t color_standard, uint32_t color_range, float *out_matrix);

/* Graph thread. The stated CPU path: copies NV12 planes into pooled
 * textures for shells whose zero-copy import is not wired yet. The copy is
 * counted; prefer ck_session_submit_frame. */
ck_status ck_session_submit_frame_copy(ck_session *session, const ck_frame_desc *desc, const uint8_t *y, uint32_t y_stride, const uint8_t *uv, uint32_t uv_stride);

/* Graph thread. Zero-copy submission of a platform hardware buffer
 * (AHardwareBuffer). Any status other than CK_OK means this stream falls
 * back to ck_session_submit_frame_copy. */
ck_status ck_session_submit_hardware_buffer(ck_session *session, const ck_frame_desc *desc, void *hardware_buffer);

/* Graph thread. Reports one finished frame: measured whole-pipeline time
 * plus current thermal pressure. Returns the degradation level in effect
 * for the next frame. */
ck_degrade_level ck_session_report_frame(ck_session *session, uint32_t frame_time_us, ck_thermal thermal);

/* Graph thread. The level currently in effect. */
ck_degrade_level ck_session_degrade_level(const ck_session *session);

/* Graph thread. Stands the face tracking worker up from a model bundle
 * (a MediaPipe .task file). The bundle bytes are copied; the caller may
 * release them on return. Builds without the inference stack report
 * unsupported. */
ck_status ck_session_enable_face_tracking(ck_session *session, const uint8_t *task_bytes, size_t task_len, int32_t threads);
void ck_session_disable_face_tracking(ck_session *session);

/* Graph thread. Stands the segmentation worker up from a raw model
 * (a selfie or hair segmenter .tflite file, not bundled the way
 * face_landmarker.task is). The model bytes are copied; the caller may
 * release them on return. Builds without the inference stack report
 * unsupported. */
ck_status ck_session_enable_segmentation(ck_session *session, const uint8_t *model_bytes, size_t model_len, int32_t threads);
void ck_session_disable_segmentation(ck_session *session);

/* Graph thread. Feeds one NV12 frame to the tracking worker. The planes
 * are CPU addresses valid for the duration of the call; the worker copies
 * and returns immediately, dropping stale frames in favor of this one.
 * Feeds the segmentation worker the same frame if it is enabled too. */
ck_status ck_session_track_frame(ck_session *session, const ck_frame_desc *desc, const uint8_t *y, uint32_t y_stride, const uint8_t *uv, uint32_t uv_stride);

/* Graph thread. Reads the newest tracking result into caller memory.
 * Reports CK_AGAIN until the worker has published its first result. */
ck_status ck_session_face_result(ck_session *session, ck_face_result *out_result);

/* Effect identifiers for ck_session_set_beauty. Values clamp to zero and
 * one; zero disables the effect. */
#define CK_BEAUTY_SMOOTH 0
#define CK_BEAUTY_WHITEN 1
#define CK_BEAUTY_THIN_FACE 2
#define CK_BEAUTY_BIG_EYE 3
#define CK_BEAUTY_LIPSTICK 4
#define CK_BEAUTY_BLUSH 5

/* Graph thread. Stands the beauty chain up for a session. resource_path
 * names the directory holding the effect engine's shader and image
 * assets. Builds without the effects engine report unsupported. */
ck_status ck_session_enable_beauty(ck_session *session, const char *resource_path);
void ck_session_disable_beauty(ck_session *session);

/* Graph thread. Sets one beauty effect's strength; see the CK_BEAUTY_*
 * identifiers above. Reports CK_AGAIN until beauty is enabled. */
ck_status ck_session_set_beauty(ck_session *session, int32_t effect, float value);

/* Graph thread, web only. Uploads one of whiten's four lookup textures -
 * slot 0 gray, 1 origin, 2 skin, 3 custom. rgba is a caller-decoded
 * image; whiten stays inert until all four slots are loaded. Reports
 * CK_UNSUPPORTED on every other target, where whiten runs through the
 * native beauty engine instead. */
ck_status ck_session_set_beauty_lut(ck_session *session, int32_t slot, const uint8_t *rgba, uint32_t width, uint32_t height);

/* Graph thread, web only. Uploads lipstick's (CK_BEAUTY_LIPSTICK) or
 * blush's (CK_BEAUTY_BLUSH) own source image - caller-decoded the same
 * way ck_session_set_beauty_lut's rgba is. Reports CK_UNSUPPORTED on
 * every other target. */
ck_status ck_session_set_beauty_makeup_texture(ck_session *session, int32_t effect, const uint8_t *rgba, uint32_t width, uint32_t height);

/* Graph thread, web only. Feeds one frame's tracked face landmarks into
 * a session directly - there is no internal tracking worker to drive
 * CK_BEAUTY_THIN_FACE/CK_BEAUTY_BIG_EYE/CK_BEAUTY_LIPSTICK/CK_BEAUTY_BLUSH
 * on web (ck_session_enable_face_tracking reports CK_ERROR_UNSUPPORTED
 * there); the caller runs its own tracker and hands the result straight
 * in. points holds point_count * 3 floats (x, y in frame pixels, z in
 * the same scale, matching ck_face_result's own landmarks convention);
 * point_count must be CK_FACE_LANDMARK_COUNT, or zero to clear any
 * previously set landmarks (no face this frame). Reports CK_UNSUPPORTED
 * on every other target, where ck_session_track_frame feeds the same
 * effects instead. */
ck_status ck_session_set_face_landmarks(ck_session *session, const float *points, uint32_t point_count);

/* Graph thread. The CPU-copy path for a single-plane BGRA8/RGBA8 frame -
 * a canvas or video element's own byte buffer, with no native GPU handle
 * behind it the way ck_session_submit_frame's zero-copy path needs. Same
 * shape as ck_session_submit_frame_copy, one interleaved plane instead
 * of NV12's two. */
ck_status ck_session_submit_frame_rgba_copy(ck_session *session, const ck_frame_desc *desc, const uint8_t *rgba, uint32_t stride);

/* Graph thread. Runs the beauty chain over one RGBA frame on the calling
 * thread, reading the newest tracking result for the landmark driven
 * effects when face tracking is enabled. The stated CPU path; live
 * preview integration on the render thread is the device side of this
 * row. */
ck_status ck_session_beautify_frame(ck_session *session, const uint8_t *rgba_in, uint32_t width, uint32_t height, uint8_t *rgba_out);

/* Graph thread. Replaces any currently active lens (unsplicing it first)
 * with the one manifest_json describes, splices its node subgraph into
 * the session's frame graph, and applies its default effect values to
 * the beauty chain if one is enabled. The bytes are copied; the caller
 * may release them on return. A manifest that fails to parse, or that
 * names a node type this build does not support, activates nothing and
 * reports CK_INVALID_ARGUMENT. */
ck_status ck_session_activate_lens(ck_session *session, const uint8_t *manifest_json, size_t manifest_len);

/* Graph thread. Same activation ck_session_activate_lens performs, from
 * bundle_path/manifest.json, plus one further step that function cannot
 * do without a bundle path to read from: a bgfx program is created for
 * every shader.pass node the lens splices, loading whichever compiled
 * variant under bundle_path/shaders/ matches the running platform's
 * active graphics backend. A shader failing to load leaves that one
 * pass without a program rather than failing the whole activation - a
 * packaged bundle was already proven to compile by the validator, so a
 * load failure here is a runtime anomaly, not an authoring error. */
ck_status ck_session_activate_lens_from_directory(ck_session *session, const uint8_t *bundle_path, size_t bundle_path_len);

/* Graph thread. Unsplices the active lens and frees everything its
 * activation allocated. Accepts no active lens and does nothing. */
void ck_session_deactivate_lens(ck_session *session);

/* Graph thread. Advances the active lens by dt_us of real time,
 * evaluating its compiled triggers against signals and applying every
 * effect value that changed as a result to the beauty chain, if one is
 * enabled. Reports CK_AGAIN with no active lens. */
ck_status ck_session_tick_lens(ck_session *session, uint32_t dt_us, const ck_lens_signals *signals);

#if !defined(__cplusplus) && (__STDC_VERSION__ >= 201112L)
_Static_assert(sizeof(ck_frame_desc) == 32, "ck_frame_desc layout is frozen");
_Static_assert(sizeof(ck_landmarks) == 24, "ck_landmarks layout is frozen");
_Static_assert(sizeof(ck_engine_config) == 8, "ck_engine_config layout is frozen");
_Static_assert(sizeof(ck_session_config) == 8, "ck_session_config layout is frozen");
_Static_assert(sizeof(ck_face_result) == 5968, "ck_face_result layout is frozen");
_Static_assert(offsetof(ck_face_result, landmarks) == 24, "ck_face_result layout is frozen");
_Static_assert(sizeof(ck_renderer_desc) == (sizeof(void *) == 8 ? 16 : 12), "ck_renderer_desc layout is frozen");
_Static_assert(sizeof(ck_frame_planes) == 32, "ck_frame_planes layout is frozen");
_Static_assert(sizeof(ck_lens_signals) == 232, "ck_lens_signals layout is frozen");
_Static_assert(offsetof(ck_lens_signals, world_tracking_state) == 8, "ck_lens_signals layout is frozen");
_Static_assert(offsetof(ck_lens_signals, blendshapes) == 24, "ck_lens_signals layout is frozen");
#endif

#ifdef __cplusplus
}
#endif

#endif /* CAMERAKIT_H */
