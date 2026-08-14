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
#define CK_ABI_MINOR 2u
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

/* Graph thread. Reports one finished frame: measured whole-pipeline time
 * plus current thermal pressure. Returns the degradation level in effect
 * for the next frame. */
ck_degrade_level ck_session_report_frame(ck_session *session, uint32_t frame_time_us, ck_thermal thermal);

/* Graph thread. The level currently in effect. */
ck_degrade_level ck_session_degrade_level(const ck_session *session);

#if !defined(__cplusplus) && (__STDC_VERSION__ >= 201112L)
_Static_assert(sizeof(ck_frame_desc) == 32, "ck_frame_desc layout is frozen");
_Static_assert(sizeof(ck_landmarks) == 24, "ck_landmarks layout is frozen");
_Static_assert(sizeof(ck_engine_config) == 8, "ck_engine_config layout is frozen");
_Static_assert(sizeof(ck_session_config) == 8, "ck_session_config layout is frozen");
_Static_assert(sizeof(ck_renderer_desc) == (sizeof(void *) == 8 ? 16 : 12), "ck_renderer_desc layout is frozen");
_Static_assert(sizeof(ck_frame_planes) == 32, "ck_frame_planes layout is frozen");
#endif

#ifdef __cplusplus
}
#endif

#endif /* CAMERAKIT_H */
