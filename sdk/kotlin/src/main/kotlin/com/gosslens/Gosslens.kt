package com.gosslens

import android.view.Surface
import java.nio.ByteBuffer

// The Kotlin face of the goss_ ABI. The native names mirror the C surface one
// to one and carry no logic; Session and Engine below are the idiomatic
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
data class EngineConfig(val texturePoolCapacity: Int, val stagingPoolCapacity: Int)

/** frameBudgetUs is the whole-pipeline frame time the degradation
 * policy holds the session to; zero means the built-in 30 fps budget. */
data class SessionConfig(val frameBudgetUs: Int)

class Engine private constructor(internal val handle: Long) : AutoCloseable {
    private var closed = false

    companion object {
        /** Null config means the core's own defaults, same as C's null. */
        fun create(config: EngineConfig? = null): Engine {
            val handle = Gosslens.nativeEngineCreate(
                config?.texturePoolCapacity ?: -1,
                config?.stagingPoolCapacity ?: -1,
            )
            check(handle != 0L) { "engine create failed" }
            return Engine(handle)
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

    fun renderFrame(session: Session?): Boolean =
        Gosslens.nativeRenderFrame(handle, session?.handle ?: 0L) == 0

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
class FaceResult {
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
class LensSignals {
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
class HandResult {
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
class PoseResult {
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

class Session private constructor(internal val handle: Long) : AutoCloseable {
    private var closed = false

    companion object {
        /** Null config means the core's own defaults, same as C's null. */
        fun create(engine: Engine, config: SessionConfig? = null): Session {
            val handle = Gosslens.nativeSessionCreate(engine.handle, config?.frameBudgetUs ?: -1)
            check(handle != 0L) { "session create failed" }
            return Session(handle)
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
    fun poseResult(result: PoseResult): Boolean {
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
    fun handResult(result: HandResult): Boolean {
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
    fun faceResult(result: FaceResult): Boolean {
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
    fun tickLens(dtUs: Int, signals: LensSignals): Boolean =
        Gosslens.nativeTickLens(handle, dtUs, signals.buffer) == 0

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
