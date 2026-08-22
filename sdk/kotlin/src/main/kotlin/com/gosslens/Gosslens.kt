package com.gosslens

import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder

// The Kotlin face of the goss_ ABI. The native names mirror the C surface one
// to one and carry no logic; GossSession and GossEngine below are the idiomatic
// wrappers the app consumes.
object Gosslens {
    init {
        System.loadLibrary("gosslens")
    }

    internal external fun nativeAbiVersion(): Int
    internal external fun nativeEngineCreate(texturePoolCapacity: Int, stagingPoolCapacity: Int): Long
    internal external fun nativeEngineDestroy(engine: Long)
    internal external fun nativeInitRenderer(engine: Long, surface: Surface, width: Int, height: Int): Int
    internal external fun nativeResize(engine: Long, width: Int, height: Int)
    internal external fun nativeRequestScreenshot(engine: Long, pathBuffer: ByteBuffer, pathLen: Int): Int
    internal external fun nativeCapturePhoto(engine: Long, session: Long, dataBuffer: ByteBuffer, dataCapacity: Long, infoBuffer: ByteBuffer): Int
    internal external fun nativeCaptureLiveFrame(engine: Long, session: Long, format: Int, dataBuffer: ByteBuffer, dataCapacity: Long, infoBuffer: ByteBuffer): Int
    internal external fun nativeCaptureStill(engine: Long, session: Long, width: Int, height: Int, supersample: Int, format: Int, quality: Int, colorSpace: Int, bitDepth: Int, dataBuffer: ByteBuffer, dataCapacity: Long, infoBuffer: ByteBuffer): Int
    internal external fun nativeRecordingStart(engine: Long, session: Long, pathBuffer: ByteBuffer, pathLen: Int, width: Int, height: Int, bitrate: Int, codec: Int): Int
    internal external fun nativeRecordingStop(engine: Long): Int
    internal external fun nativeSubmitWorld(session: Long, stateBuffer: ByteBuffer, planesBuffer: ByteBuffer, planeCount: Int, anchorsBuffer: ByteBuffer, anchorCount: Int, lightBuffer: ByteBuffer): Int
    internal external fun nativeSubmitAudio(session: Long, samplesBuffer: ByteBuffer, frameCount: Int, sampleRate: Int, channels: Int, timestampUs: Long): Int
    internal external fun nativeRenderFrame(engine: Long, session: Long): Int
    internal external fun nativeSessionCreate(engine: Long, frameBudgetUs: Int): Long
    internal external fun nativeSessionDestroy(session: Long)
    internal external fun nativeSubmitFrameCopy(
        session: Long,
        yBuffer: ByteBuffer,
        yStride: Int,
        uvBuffer: ByteBuffer,
        uvStride: Int,
        width: Int,
        height: Int,
        flags: Int,
        colorStandard: Int,
        colorRange: Int,
        timestampUs: Long,
    ): Int
    internal external fun nativeReportFrame(session: Long, frameTimeUs: Int, thermal: Int): Int
    internal external fun nativeEnableFaceTracking(session: Long, taskBuffer: ByteBuffer, taskLen: Int, threads: Int): Int
    internal external fun nativeDisableFaceTracking(session: Long)
    internal external fun nativeEnableHandTracking(session: Long, taskBuffer: ByteBuffer, taskLen: Int, threads: Int): Int
    internal external fun nativeDisableHandTracking(session: Long)
    internal external fun nativeHandResult(session: Long, resultBuffer: ByteBuffer): Int
    internal external fun nativeEnablePoseTracking(session: Long, taskBuffer: ByteBuffer, taskLen: Int, threads: Int): Int
    internal external fun nativeDisablePoseTracking(session: Long)
    internal external fun nativePoseResult(session: Long, resultBuffer: ByteBuffer): Int
    internal external fun nativeFacePose(session: Long, matrixBuffer: ByteBuffer): Int
    internal external fun nativeTrackFrame(
        session: Long,
        yBuffer: ByteBuffer,
        yStride: Int,
        uvBuffer: ByteBuffer,
        uvStride: Int,
        width: Int,
        height: Int,
        colorStandard: Int,
        colorRange: Int,
        timestampUs: Long,
    ): Int
    internal external fun nativeFaceResult(session: Long, resultBuffer: ByteBuffer): Int
    internal external fun nativeEnableBeauty(session: Long, pathBuffer: ByteBuffer, pathLen: Int): Int
    internal external fun nativeDisableBeauty(session: Long)
    internal external fun nativeSetBeauty(session: Long, effect: Int, value: Float): Int
    internal external fun nativeBeautifyFrame(session: Long, rgbaIn: ByteBuffer, rgbaOut: ByteBuffer, width: Int, height: Int): Int
    internal external fun nativeActivateLens(session: Long, manifestBuffer: ByteBuffer, manifestLen: Int): Int
    internal external fun nativeDeactivateLens(session: Long)
    internal external fun nativeTickLens(session: Long, dtUs: Int, signalsBuffer: ByteBuffer): Int
    internal external fun nativeParameterValue(session: Long, nameBuffer: ByteBuffer, nameLen: Int, outBuffer: ByteBuffer): Int
    internal external fun nativePullAudio(session: Long, outBuffer: ByteBuffer, frames: Int): Int
    internal external fun nativeMixOutputAudio(session: Long, micBuffer: ByteBuffer?, outBuffer: ByteBuffer, frameCount: Int, sampleRate: Int, channels: Int): Int
    internal external fun nativeSetCameraControls(session: Long, buffer: ByteBuffer): Int
    internal external fun nativeCameraControls(session: Long, buffer: ByteBuffer): Int
    internal external fun nativeFireEvent(session: Long, nameBuffer: ByteBuffer, nameLen: Int): Int
    internal external fun nativeDefineSource(session: Long, nameBuffer: ByteBuffer, nameLen: Int): Int
    internal external fun nativeRemoveSource(session: Long, nameBuffer: ByteBuffer, nameLen: Int): Int
    internal external fun nativeSubmitSourceFrameRgba(session: Long, nameBuffer: ByteBuffer, nameLen: Int, rgbaBuffer: ByteBuffer, width: Int, height: Int, stride: Int, pixelFormat: Int): Int
    internal external fun nativeSetLayout(session: Long, arrangement: Int): Int
    internal external fun nativeClearLayout(session: Long): Int
    internal external fun nativeSubmitLocation(session: Long, latitude: Double, longitude: Double, accuracyM: Float, timestampUs: Long): Int
    internal external fun nativeSetGeofence(session: Long, latitude: Double, longitude: Double, radiusM: Double): Int
    internal external fun nativeClearGeofence(session: Long): Int
    internal external fun nativeSubmitHardwareBuffer(
        session: Long,
        hardwareBuffer: android.hardware.HardwareBuffer,
        width: Int,
        height: Int,
        flags: Int,
        colorStandard: Int,
        colorRange: Int,
        timestampUs: Long,
    ): Int
    internal external fun nativeDegradeLevel(session: Long): Int
    internal external fun nativeYuvToRgb(standard: Int, range: Int, outBuffer: ByteBuffer): Int
    internal external fun nativeActivateLensFromDirectory(session: Long, pathBuffer: ByteBuffer, pathLen: Int): Int

    const val COLOR_BT601 = 0
    const val COLOR_BT709 = 1
    const val COLOR_BT2020 = 2
    const val RANGE_VIDEO = 0
    const val RANGE_FULL = 1
    const val FLAG_MIRROR = 1
    const val ROTATION_SHIFT = 8
    const val FACE_LANDMARK_COUNT = 478
    const val FACE_BLENDSHAPE_COUNT = 52
    const val FACE_RESULT_BYTES = 5968
    const val HAND_LANDMARK_COUNT = 21
    const val HAND_MAX = 2
    const val HAND_RESULT_BYTES = 560
    const val POSE_LANDMARK_COUNT = 33
    const val POSE_RESULT_BYTES = 688
    const val GESTURE_NONE = 0
    const val GESTURE_CLOSED_FIST = 1
    const val GESTURE_OPEN_PALM = 2
    const val GESTURE_POINTING_UP = 3
    const val GESTURE_THUMB_DOWN = 4
    const val GESTURE_THUMB_UP = 5
    const val GESTURE_VICTORY = 6
    const val GESTURE_ILOVEYOU = 7
    const val LENS_SIGNALS_BYTES = 232
    const val STATUS_AGAIN = 7

    fun abiVersion(): Int = nativeAbiVersion()

    /** The 4x4 YUV-to-RGB conversion matrix for a color standard and
     * range, column-major, sixteen floats. */
    fun yuvToRgb(colorStandard: Int, colorRange: Int): FloatArray {
        val buffer = ByteBuffer.allocateDirect(16 * 4).order(java.nio.ByteOrder.nativeOrder())
        check(nativeYuvToRgb(colorStandard, colorRange, buffer) == 0) { "unknown color standard or range" }
        val matrix = FloatArray(16)
        buffer.asFloatBuffer().get(matrix)
        return matrix
    }

    fun flagsFor(rotationDegrees: Int, mirrored: Boolean): Int {
        val quarterTurns = ((rotationDegrees % 360) / 90) and 0x3
        var flags = quarterTurns shl ROTATION_SHIFT
        if (mirrored) flags = flags or FLAG_MIRROR
        return flags
    }
}

/** Pool capacities for the engine's texture and staging pools; the
 * core clamps and defaults exactly as the C config does. */
data class GossEngineConfig(val texturePoolCapacity: Int, val stagingPoolCapacity: Int)

/** frameBudgetUs is the whole-pipeline frame time the degradation
 * policy holds the session to; zero means the built-in 30 fps budget. */
data class GossSessionConfig(val frameBudgetUs: Int)

/** Declarative camera-hardware intent. The engine normalizes every field; the
 * app reads it back and drives CameraX. Modes: flash 0 off/1 on/2 auto; focus
 * 0 auto/1 locked/2 point; exposure 0 auto/1 locked. Points are normalized. */
data class GossCameraControls(
    val flashMode: Int = 0,
    val torch: Int = 0,
    val focusMode: Int = 0,
    val exposureMode: Int = 0,
    val focusPointX: Float = 0.5f,
    val focusPointY: Float = 0.5f,
    val exposureLinked: Int = 1,
    val exposurePointX: Float = 0.5f,
    val exposurePointY: Float = 0.5f,
    val exposureBiasEv: Float = 0f,
    val zoomFactor: Float = 1f,
    val maxZoomFactor: Float = 0f,
    val mirrorSavePolicy: Int = 0,
)

class GossEngine private constructor(internal val handle: Long) : AutoCloseable {
    private var closed = false

    companion object {
        /** Null config means the core's own defaults, same as C's null. */
        fun create(config: GossEngineConfig? = null): GossEngine {
            val handle = Gosslens.nativeEngineCreate(
                config?.texturePoolCapacity ?: -1,
                config?.stagingPoolCapacity ?: -1,
            )
            check(handle != 0L) { "engine create failed" }
            return GossEngine(handle)
        }
    }

    fun initRenderer(surface: Surface, width: Int, height: Int) {
        check(Gosslens.nativeInitRenderer(handle, surface, width, height) == 0) { "renderer init failed" }
    }

    fun resize(width: Int, height: Int) = Gosslens.nativeResize(handle, width, height)

    /** Requests a screenshot of the next presented frame, written as
     * [path] plus a ".tga" suffix the renderer's own callback appends -
     * debug/test tooling (the conformance run this exists for), never a
     * user-facing control. */
    fun requestScreenshot(path: String): Boolean {
        val bytes = path.toByteArray(Charsets.UTF_8)
        val buffer = ByteBuffer.allocateDirect(bytes.size)
        buffer.put(bytes)
        buffer.rewind()
        return Gosslens.nativeRequestScreenshot(handle, buffer, bytes.size) == 0
    }

    fun renderFrame(session: GossSession?): Boolean =
        Gosslens.nativeRenderFrame(handle, session?.handle ?: 0L) == 0

    /** Starts recording the session's rendered frames, effects baked
     * in, into an MP4 at [path]. One recording per engine; every
     * rendered frame appends until [stopRecording]. */
    fun startRecording(session: GossSession, path: String, width: Int = 0, height: Int = 0, bitrate: Int = 0, hevc: Boolean = false): Boolean {
        val bytes = path.toByteArray(Charsets.UTF_8)
        val buffer = ByteBuffer.allocateDirect(bytes.size)
        buffer.put(bytes)
        buffer.rewind()
        return Gosslens.nativeRecordingStart(handle, session.handle, buffer, bytes.size, width, height, bitrate, if (hevc) 1 else 0) == 0
    }

    /** Stops the recording, flushing in-flight frames and finalizing
     * the file. */
    fun stopRecording(): Boolean = Gosslens.nativeRecordingStop(handle) == 0

    /** Feeds interleaved f32 PCM into the session: the engine's level
     * and beat analysis drives audio triggers, and an active recording
     * muxes it where the backend supports audio. [samples] is a direct
     * float buffer. */
    fun submitAudio(session: GossSession, samples: ByteBuffer, frameCount: Int, sampleRate: Int, channels: Int, timestampUs: Long): Boolean =
        Gosslens.nativeSubmitAudio(session.handle, samples, frameCount, sampleRate, channels, timestampUs) == 0

    /** Renders like renderFrame and returns the composited output
     * encoded as PNG bytes, sized by a probe call first. Deterministic:
     * the same composited pixels, the same bytes. Null when the
     * renderer is unavailable. */
    fun capturePhoto(session: GossSession?): ByteArray? {
        val info = ByteBuffer.allocateDirect(16).order(ByteOrder.nativeOrder())
        val probe = ByteBuffer.allocateDirect(1)
        val probeStatus = Gosslens.nativeCapturePhoto(handle, session?.handle ?: 0L, probe, 0L, info)
        val needed = info.getLong(0)
        if (probeStatus == 0 && needed == 0L) return ByteArray(0)
        if (needed <= 0L) return null
        val data = ByteBuffer.allocateDirect(needed.toInt())
        if (Gosslens.nativeCapturePhoto(handle, session?.handle ?: 0L, data, needed, info) != 0) return null
        val encoded = ByteArray(info.getLong(0).toInt())
        data.get(encoded)
        return encoded
    }

    /** The composited frame in a WebRTC format (BGRA8 = 3 by default, NV12 = 0
     * for a hardware encoder), the supported per-frame output for a live
     * broadcast source. width and height are the render size; returns the
     * packed frame bytes, or null when the renderer is away. */
    fun captureLiveFrame(session: GossSession?, width: Int, height: Int, format: Int = 3): ByteArray? {
        if (width <= 0 || height <= 0) return null
        val info = ByteBuffer.allocateDirect(16).order(ByteOrder.nativeOrder())
        val pixels = width.toLong() * height
        val capacity = if (format == 0) pixels + pixels / 2 else pixels * 4
        val data = ByteBuffer.allocateDirect(capacity.toInt())
        if (Gosslens.nativeCaptureLiveFrame(handle, session?.handle ?: 0L, format, data, capacity, info) != 0) return null
        val frame = ByteArray(capacity.toInt())
        data.get(frame)
        return frame
    }

    /** A high-resolution still: the composited frame at its own or a
     * requested resolution, encoded as PNG (0), JPEG (1) or HEIC (2).
     * colorSpace tags the gamut (0 sRGB, 1 P3, 2 Rec2020); bitDepth 16 is
     * the PNG high-bit-depth path. Null when the renderer/backend is away. */
    fun captureStill(session: GossSession?, width: Int = 0, height: Int = 0, supersample: Int = 0, format: Int = 0, quality: Int = 0, colorSpace: Int = 0, bitDepth: Int = 8): ByteArray? {
        val info = ByteBuffer.allocateDirect(16).order(ByteOrder.nativeOrder())
        val probe = ByteBuffer.allocateDirect(1)
        val probeStatus = Gosslens.nativeCaptureStill(handle, session?.handle ?: 0L, width, height, supersample, format, quality, colorSpace, bitDepth, probe, 0L, info)
        val needed = info.getLong(0)
        if (probeStatus == 0 && needed == 0L) return ByteArray(0)
        if (needed <= 0L) return null
        val data = ByteBuffer.allocateDirect(needed.toInt())
        if (Gosslens.nativeCaptureStill(handle, session?.handle ?: 0L, width, height, supersample, format, quality, colorSpace, bitDepth, data, needed, info) != 0) return null
        val encoded = ByteArray(info.getLong(0).toInt())
        data.get(encoded)
        return encoded
    }

    // Idempotent like destroy() everywhere else - a second close() must
    // not hand the native side an already-freed handle.
    override fun close() {
        if (closed) return
        closed = true
        Gosslens.nativeEngineDestroy(handle)
    }
}

/** One tracking result read back from the core. The buffer mirrors the
 * frozen C layout; parse() lifts the fields into Kotlin values without
 * allocating per frame. */
class GossFaceResult {
    internal val buffer: ByteBuffer =
        ByteBuffer.allocateDirect(Gosslens.FACE_RESULT_BYTES).order(java.nio.ByteOrder.nativeOrder())

    var frameSerial: Long = 0; private set
    var timestampUs: Long = 0; private set
    var presence: Float = 0f; private set
    var landmarkCount: Int = 0; private set

    /** x, y frame pixels and z, three floats per landmark. */
    val landmarks = FloatArray(Gosslens.FACE_LANDMARK_COUNT * 3)
    val blendshapes = FloatArray(Gosslens.FACE_BLENDSHAPE_COUNT)

    internal fun parse() {
        buffer.rewind()
        frameSerial = buffer.long
        timestampUs = buffer.long
        presence = buffer.float
        landmarkCount = buffer.int
        buffer.asFloatBuffer().let { floats ->
            floats.get(landmarks)
            floats.get(blendshapes)
        }
    }
}

/** The live signals one tick evaluates a lens's compiled triggers
 * against. The buffer mirrors the frozen goss_lens_signals layout
 * (booleans and a reserved byte, then the padding to the first double
 * at offset 8, then blendshapes at offset 24) - absolute puts, not
 * relative, so this doesn't depend on writing the padding by hand. */
class GossLensSignals {
    internal val buffer: ByteBuffer =
        ByteBuffer.allocateDirect(Gosslens.LENS_SIGNALS_BYTES).order(java.nio.ByteOrder.nativeOrder())

    /** blendshapes may be shorter than FACE_BLENDSHAPE_COUNT; the rest
     * reads as zero. Pass hasFace = false when no face is tracked -
     * every face-driven signal then reads false regardless of what
     * blendshapes holds. */
    fun set(hasFace: Boolean, handsPresent: Boolean, tap: Boolean, worldTrackingState: Double, audioLevel: Double, blendshapes: FloatArray) {
        buffer.put(0, if (hasFace) 1 else 0)
        buffer.put(1, if (handsPresent) 1 else 0)
        buffer.put(2, if (tap) 1 else 0)
        buffer.put(3, 0)
        buffer.putDouble(8, worldTrackingState)
        buffer.putDouble(16, audioLevel)
        val floats = buffer.duplicate().order(buffer.order()).asFloatBuffer()
        for (i in 0 until Gosslens.FACE_BLENDSHAPE_COUNT) {
            floats.put(6 + i, if (i < blendshapes.size) blendshapes[i] else 0f)
        }
    }
}

/** One reusable hand tracking readout. The buffer mirrors the frozen C
 * layout; parse() lifts the fields into flat per-hand arrays without
 * allocating per frame. handedness is the model's score that the hand
 * is a right hand; gestures hold GESTURE_* classes, NONE when the
 * enabled bundle carries no gesture models. */
class GossHandResult {
    internal val buffer: ByteBuffer =
        ByteBuffer.allocateDirect(Gosslens.HAND_RESULT_BYTES).order(java.nio.ByteOrder.nativeOrder())

    var frameSerial: Long = 0; private set
    var timestampUs: Long = 0; private set
    var handCount: Int = 0; private set

    val presences = FloatArray(Gosslens.HAND_MAX)
    val handednesses = FloatArray(Gosslens.HAND_MAX)
    val gestures = IntArray(Gosslens.HAND_MAX)
    val gestureScores = FloatArray(Gosslens.HAND_MAX)

    /** Hand h's point p sits at (h * HAND_LANDMARK_COUNT + p) * 3. */
    val landmarks = FloatArray(Gosslens.HAND_MAX * Gosslens.HAND_LANDMARK_COUNT * 3)

    internal fun parse() {
        buffer.rewind()
        frameSerial = buffer.long
        timestampUs = buffer.long
        handCount = buffer.int
        buffer.int
        for (handAt in 0 until Gosslens.HAND_MAX) {
            presences[handAt] = buffer.float
            handednesses[handAt] = buffer.float
            gestures[handAt] = buffer.int
            gestureScores[handAt] = buffer.float
            val floats = buffer.asFloatBuffer()
            floats.get(landmarks, handAt * Gosslens.HAND_LANDMARK_COUNT * 3, Gosslens.HAND_LANDMARK_COUNT * 3)
            buffer.position(buffer.position() + Gosslens.HAND_LANDMARK_COUNT * 3 * 4)
        }
    }
}

/** One reusable pose tracking readout. The buffer mirrors the frozen C
 * layout; parse() lifts the fields into flat arrays without allocating
 * per frame. */
class GossPoseResult {
    internal val buffer: ByteBuffer =
        ByteBuffer.allocateDirect(Gosslens.POSE_RESULT_BYTES).order(java.nio.ByteOrder.nativeOrder())

    var frameSerial: Long = 0; private set
    var timestampUs: Long = 0; private set
    var presence: Float = 0f; private set
    var landmarkCount: Int = 0; private set

    /** x, y frame pixels and z, three floats per landmark. */
    val landmarks = FloatArray(Gosslens.POSE_LANDMARK_COUNT * 3)
    val visibilities = FloatArray(Gosslens.POSE_LANDMARK_COUNT)
    val presences = FloatArray(Gosslens.POSE_LANDMARK_COUNT)

    internal fun parse() {
        buffer.rewind()
        frameSerial = buffer.long
        timestampUs = buffer.long
        presence = buffer.float
        landmarkCount = buffer.int
        buffer.asFloatBuffer().let { floats ->
            floats.get(landmarks)
            floats.get(visibilities)
            floats.get(presences)
        }
    }
}

class GossSession private constructor(internal val handle: Long) : AutoCloseable {
    private var closed = false

    companion object {
        /** Null config means the core's own defaults, same as C's null. */
        fun create(engine: GossEngine, config: GossSessionConfig? = null): GossSession {
            val handle = Gosslens.nativeSessionCreate(engine.handle, config?.frameBudgetUs ?: -1)
            check(handle != 0L) { "session create failed" }
            return GossSession(handle)
        }
    }

    fun submitFrameCopy(
        y: ByteBuffer,
        yStride: Int,
        uv: ByteBuffer,
        uvStride: Int,
        width: Int,
        height: Int,
        rotationDegrees: Int,
        mirrored: Boolean,
        colorStandard: Int = Gosslens.COLOR_BT709,
        colorRange: Int = Gosslens.RANGE_VIDEO,
        timestampUs: Long,
    ): Boolean = Gosslens.nativeSubmitFrameCopy(
        handle, y, yStride, uv, uvStride, width, height,
        Gosslens.flagsFor(rotationDegrees, mirrored),
        colorStandard, colorRange, timestampUs,
    ) == 0

    fun reportFrame(frameTimeUs: Int, thermal: Int): Int =
        Gosslens.nativeReportFrame(handle, frameTimeUs, thermal)

    fun degradeLevel(): Int = Gosslens.nativeDegradeLevel(handle)

    fun enableFaceTracking(taskBundle: ByteBuffer, threads: Int): Boolean =
        Gosslens.nativeEnableFaceTracking(handle, taskBundle, taskBundle.remaining(), threads) == 0

    fun disableFaceTracking() = Gosslens.nativeDisableFaceTracking(handle)

    /** Stands the hand tracking worker up from a hand landmarker or
     * gesture recognizer task bundle; up to two hands publish per frame,
     * with canned gestures scored when the bundle carries the models. */
    fun enableHandTracking(taskBundle: ByteBuffer, threads: Int): Boolean =
        Gosslens.nativeEnableHandTracking(handle, taskBundle, taskBundle.remaining(), threads) == 0

    fun disableHandTracking() = Gosslens.nativeDisableHandTracking(handle)

    /** Stands the pose tracking worker up from a pose landmarker task
     * bundle; one 33-point body publishes per frame. */
    fun enablePoseTracking(taskBundle: ByteBuffer, threads: Int): Boolean =
        Gosslens.nativeEnablePoseTracking(handle, taskBundle, taskBundle.remaining(), threads) == 0

    fun disablePoseTracking() = Gosslens.nativeDisablePoseTracking(handle)

    /** Fills [result] with the newest pose tracking output; false until
     * the worker publishes its first result. */
    fun poseResult(result: GossPoseResult): Boolean {
        val status = Gosslens.nativePoseResult(handle, result.buffer)
        if (status != 0) return false
        result.parse()
        return true
    }

    private val facePoseBuffer: ByteBuffer =
        ByteBuffer.allocateDirect(16 * 4).order(java.nio.ByteOrder.nativeOrder())

    /** Fills [matrix] with the column-major head transform - canonical
     * metric space into frame pixels; false until a face is tracked. */
    fun facePose(matrix: FloatArray): Boolean {
        require(matrix.size >= 16)
        if (Gosslens.nativeFacePose(handle, facePoseBuffer) != 0) return false
        facePoseBuffer.rewind()
        facePoseBuffer.asFloatBuffer().get(matrix, 0, 16)
        return true
    }

    /** Fills [result] with the newest hand tracking output; false until
     * the worker publishes its first result. */
    fun handResult(result: GossHandResult): Boolean {
        val status = Gosslens.nativeHandResult(handle, result.buffer)
        if (status != 0) return false
        result.parse()
        return true
    }

    fun trackFrame(
        y: ByteBuffer,
        yStride: Int,
        uv: ByteBuffer,
        uvStride: Int,
        width: Int,
        height: Int,
        colorStandard: Int = Gosslens.COLOR_BT709,
        colorRange: Int = Gosslens.RANGE_VIDEO,
        timestampUs: Long,
    ): Boolean = Gosslens.nativeTrackFrame(
        handle, y, yStride, uv, uvStride, width, height, colorStandard, colorRange, timestampUs,
    ) == 0

    /** Stands the beauty chain up; [resourceDir] holds the effect engine's
     * shader and image assets on disk. */
    fun enableBeauty(resourceDir: String): Boolean {
        val bytes = resourceDir.toByteArray(Charsets.UTF_8)
        val buffer = ByteBuffer.allocateDirect(bytes.size + 1)
        buffer.put(bytes)
        buffer.put(0)
        buffer.rewind()
        return Gosslens.nativeEnableBeauty(handle, buffer, bytes.size) == 0
    }

    fun disableBeauty() = Gosslens.nativeDisableBeauty(handle)

    /** Effects in order: smooth 0, whiten 1, thin face 2, big eye 3,
     * lipstick 4, blush 5; values clamp to zero and one. */
    fun setBeauty(effect: Int, amount: Float): Boolean =
        Gosslens.nativeSetBeauty(handle, effect, amount) == 0

    fun setSmooth(amount: Float) = setBeauty(0, amount)
    fun setWhiten(amount: Float) = setBeauty(1, amount)
    fun setThinFace(amount: Float) = setBeauty(2, amount)
    fun setBigEye(amount: Float) = setBeauty(3, amount)
    fun setLipstick(amount: Float) = setBeauty(4, amount)
    fun setBlush(amount: Float) = setBeauty(5, amount)

    fun beautifyFrame(rgbaIn: ByteBuffer, rgbaOut: ByteBuffer, width: Int, height: Int): Boolean =
        Gosslens.nativeBeautifyFrame(handle, rgbaIn, rgbaOut, width, height) == 0

    /** Fills [result] with the newest tracking output; false until the
     * worker publishes its first result. */
    fun faceResult(result: GossFaceResult): Boolean {
        val status = Gosslens.nativeFaceResult(handle, result.buffer)
        if (status != 0) return false
        result.parse()
        return true
    }

    /** Replaces any currently active lens with the one manifestJson
     * describes, splicing its nodes into the session graph. */
    fun activateLens(manifestJson: ByteArray): Boolean {
        val buffer = ByteBuffer.allocateDirect(manifestJson.size)
        buffer.put(manifestJson)
        buffer.rewind()
        return Gosslens.nativeActivateLens(handle, buffer, manifestJson.size) == 0
    }

    /** Activates a lens from an on-disk .glens bundle directory. */
    fun activateLensFromDirectory(bundlePath: String): Boolean {
        val bytes = bundlePath.toByteArray(Charsets.UTF_8)
        val buffer = ByteBuffer.allocateDirect(bytes.size)
        buffer.put(bytes)
        buffer.rewind()
        return Gosslens.nativeActivateLensFromDirectory(handle, buffer, bytes.size) == 0
    }

    fun deactivateLens() = Gosslens.nativeDeactivateLens(handle)

    /** Advances the active lens by [dtUs] of real time and applies
     * whatever effect values its triggers/ramps changed to the beauty
     * chain, if one is enabled. False with no active lens. */
    fun tickLens(dtUs: Int, signals: GossLensSignals): Boolean =
        Gosslens.nativeTickLens(handle, dtUs, signals.buffer) == 0

    /** Reads a live parameter of the active lens by name, including whatever
     * a script node last wrote. Null with no active lens or no such name. */
    fun parameterValue(name: String): Float? {
        val nameBytes = name.toByteArray(Charsets.UTF_8)
        val nameBuf = ByteBuffer.allocateDirect(nameBytes.size).apply { put(nameBytes); rewind() }
        val outBuf = ByteBuffer.allocateDirect(4).order(ByteOrder.nativeOrder())
        return if (Gosslens.nativeParameterValue(handle, nameBuf, nameBytes.size, outBuf) == 0) outBuf.getFloat(0) else null
    }

    /** Pulls the next block of mixed lens audio into a direct [out] buffer
     * (frames interleaved s16) that play_sound triggers produced, for the app
     * to route to platform audio out. */
    fun pullAudio(out: ByteBuffer, frames: Int): Boolean =
        Gosslens.nativePullAudio(handle, out, frames) == 0

    /** Folds the active lens sound into the caller's outgoing call/live track:
     * [mic] (interleaved f32 at [sampleRate]/[channels], or null for silence)
     * summed with the 48 kHz mono lens mixer resampled to that rate, into [out]
     * (frameCount*channels s16). Advances the mixer once, replacing [pullAudio]. */
    fun mixOutputAudio(mic: ByteBuffer?, out: ByteBuffer, frameCount: Int, sampleRate: Int, channels: Int): Boolean =
        Gosslens.nativeMixOutputAudio(handle, mic, out, frameCount, sampleRate, channels) == 0

    /** Stores validated camera-hardware intent; the engine normalizes it. Read
     * it back with [cameraControls] and drive CameraX with the result. */
    fun setCameraControls(c: GossCameraControls): Boolean {
        val buf = ByteBuffer.allocateDirect(56).order(ByteOrder.nativeOrder())
        buf.putInt(c.flashMode); buf.putInt(c.torch); buf.putInt(c.focusMode); buf.putInt(c.exposureMode)
        buf.putFloat(c.focusPointX); buf.putFloat(c.focusPointY); buf.putInt(c.exposureLinked)
        buf.putFloat(c.exposurePointX); buf.putFloat(c.exposurePointY); buf.putFloat(c.exposureBiasEv)
        buf.putFloat(c.zoomFactor); buf.putFloat(c.maxZoomFactor); buf.putInt(c.mirrorSavePolicy); buf.putInt(0)
        buf.rewind()
        return Gosslens.nativeSetCameraControls(handle, buf) == 0
    }

    /** The normalized camera controls the app applies to the platform camera. */
    fun cameraControls(): GossCameraControls? {
        val buf = ByteBuffer.allocateDirect(56).order(ByteOrder.nativeOrder())
        if (Gosslens.nativeCameraControls(handle, buf) != 0) return null
        return GossCameraControls(
            buf.getInt(0), buf.getInt(4), buf.getInt(8), buf.getInt(12),
            buf.getFloat(16), buf.getFloat(20), buf.getInt(24),
            buf.getFloat(28), buf.getFloat(32), buf.getFloat(36),
            buf.getFloat(40), buf.getFloat(44), buf.getInt(48),
        )
    }

    /** Fires a named event the next [tickLens] delivers to the lens's
     * event('name') triggers for one tick. */
    fun fireEvent(name: String): Boolean {
        val bytes = name.toByteArray(Charsets.UTF_8)
        val buf = ByteBuffer.allocateDirect(bytes.size).apply { put(bytes); rewind() }
        return Gosslens.nativeFireEvent(handle, buf, bytes.size) == 0
    }

    private fun nameBuf(name: String): Pair<ByteBuffer, Int> {
        val b = name.toByteArray(Charsets.UTF_8)
        return ByteBuffer.allocateDirect(b.size).apply { put(b); rewind() } to b.size
    }

    /** Registers a named RGBA source for multi-source composition. */
    fun defineSource(name: String): Boolean {
        val (buf, n) = nameBuf(name)
        return Gosslens.nativeDefineSource(handle, buf, n) == 0
    }

    /** Removes a named source. */
    fun removeSource(name: String): Boolean {
        val (buf, n) = nameBuf(name)
        return Gosslens.nativeRemoveSource(handle, buf, n) == 0
    }

    /** Uploads one RGBA/BGRA frame into a named source ([pixelFormat] 3 BGRA, 4 RGBA). */
    fun submitSourceFrameRgba(name: String, rgba: ByteBuffer, width: Int, height: Int, stride: Int, pixelFormat: Int = 4): Boolean {
        val (buf, n) = nameBuf(name)
        return Gosslens.nativeSubmitSourceFrameRgba(handle, buf, n, rgba, width, height, stride, pixelFormat) == 0
    }

    /** Arranges the camera and named sources: 0 custom, 1 side-by-side, 2 top-bottom, 3 pip, 4 grid. */
    fun setLayout(arrangement: Int): Boolean = Gosslens.nativeSetLayout(handle, arrangement) == 0

    fun clearLayout(): Boolean = Gosslens.nativeClearLayout(handle) == 0

    /** Feeds a location fix for on-device geo.in_region membership. */
    fun submitLocation(latitude: Double, longitude: Double, accuracyM: Float, timestampUs: Long): Boolean =
        Gosslens.nativeSubmitLocation(handle, latitude, longitude, accuracyM, timestampUs) == 0

    /** Sets the geofence circle the app derives from a lens's intended place. */
    fun setGeofence(latitude: Double, longitude: Double, radiusM: Double): Boolean =
        Gosslens.nativeSetGeofence(handle, latitude, longitude, radiusM) == 0

    fun clearGeofence(): Boolean = Gosslens.nativeClearGeofence(handle) == 0

    fun submitHardwareBuffer(
        buffer: android.hardware.HardwareBuffer,
        width: Int,
        height: Int,
        rotationDegrees: Int,
        mirrored: Boolean,
        colorStandard: Int = Gosslens.COLOR_BT709,
        colorRange: Int = Gosslens.RANGE_VIDEO,
        timestampUs: Long,
    ): Boolean = Gosslens.nativeSubmitHardwareBuffer(
        handle, buffer, width, height,
        Gosslens.flagsFor(rotationDegrees, mirrored),
        colorStandard, colorRange, timestampUs,
    ) == 0

    override fun close() {
        if (closed) return
        closed = true
        Gosslens.nativeSessionDestroy(handle)
    }
}
