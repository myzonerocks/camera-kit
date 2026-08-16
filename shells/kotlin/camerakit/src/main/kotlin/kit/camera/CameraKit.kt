package kit.camera

import android.view.Surface
import java.nio.ByteBuffer

// The Kotlin face of the ck_ ABI. The native names mirror the C surface one
// to one and carry no logic; Session and Engine below are the idiomatic
// wrappers the app consumes.
object CameraKit {
    init {
        System.loadLibrary("camerakit")
    }

    external fun nativeAbiVersion(): Int
    external fun nativeEngineCreate(): Long
    external fun nativeEngineDestroy(engine: Long)
    external fun nativeInitRenderer(engine: Long, surface: Surface, width: Int, height: Int): Int
    external fun nativeResize(engine: Long, width: Int, height: Int)
    external fun nativeRenderFrame(engine: Long, session: Long): Int
    external fun nativeSessionCreate(engine: Long): Long
    external fun nativeSessionDestroy(session: Long)
    external fun nativeSubmitFrameCopy(
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
    external fun nativeReportFrame(session: Long, frameTimeUs: Int, thermal: Int): Int
    external fun nativeEnableFaceTracking(session: Long, taskBuffer: ByteBuffer, taskLen: Int, threads: Int): Int
    external fun nativeDisableFaceTracking(session: Long)
    external fun nativeTrackFrame(
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
    external fun nativeFaceResult(session: Long, resultBuffer: ByteBuffer): Int
    external fun nativeEnableBeauty(session: Long, pathBuffer: ByteBuffer, pathLen: Int): Int
    external fun nativeDisableBeauty(session: Long)
    external fun nativeSetBeauty(session: Long, effect: Int, value: Float): Int
    external fun nativeBeautifyFrame(session: Long, rgbaIn: ByteBuffer, rgbaOut: ByteBuffer, width: Int, height: Int): Int
    external fun nativeActivateLens(session: Long, manifestBuffer: ByteBuffer, manifestLen: Int): Int
    external fun nativeDeactivateLens(session: Long)
    external fun nativeTickLens(session: Long, dtUs: Int, signalsBuffer: ByteBuffer): Int
    external fun nativeSubmitHardwareBuffer(
        session: Long,
        hardwareBuffer: android.hardware.HardwareBuffer,
        width: Int,
        height: Int,
        flags: Int,
        colorStandard: Int,
        colorRange: Int,
        timestampUs: Long,
    ): Int

    const val FLAG_MIRROR = 1
    const val ROTATION_SHIFT = 8
    const val FACE_LANDMARK_COUNT = 478
    const val FACE_BLENDSHAPE_COUNT = 52
    const val FACE_RESULT_BYTES = 5968
    const val LENS_SIGNALS_BYTES = 232
    const val STATUS_AGAIN = 7

    fun flagsFor(rotationDegrees: Int, mirrored: Boolean): Int {
        val quarterTurns = ((rotationDegrees % 360) / 90) and 0x3
        var flags = quarterTurns shl ROTATION_SHIFT
        if (mirrored) flags = flags or FLAG_MIRROR
        return flags
    }
}

class Engine private constructor(internal val handle: Long) : AutoCloseable {
    companion object {
        fun create(): Engine {
            val handle = CameraKit.nativeEngineCreate()
            check(handle != 0L) { "engine create failed" }
            return Engine(handle)
        }
    }

    fun initRenderer(surface: Surface, width: Int, height: Int) {
        check(CameraKit.nativeInitRenderer(handle, surface, width, height) == 0) { "renderer init failed" }
    }

    fun resize(width: Int, height: Int) = CameraKit.nativeResize(handle, width, height)

    fun renderFrame(session: Session?): Boolean =
        CameraKit.nativeRenderFrame(handle, session?.handle ?: 0L) == 0

    override fun close() = CameraKit.nativeEngineDestroy(handle)
}

/** One tracking result read back from the core. The buffer mirrors the
 * frozen C layout; parse() lifts the fields into Kotlin values without
 * allocating per frame. */
class FaceResult {
    internal val buffer: ByteBuffer =
        ByteBuffer.allocateDirect(CameraKit.FACE_RESULT_BYTES).order(java.nio.ByteOrder.nativeOrder())

    var frameSerial: Long = 0; private set
    var timestampUs: Long = 0; private set
    var presence: Float = 0f; private set
    var landmarkCount: Int = 0; private set

    /** x, y frame pixels and z, three floats per landmark. */
    val landmarks = FloatArray(CameraKit.FACE_LANDMARK_COUNT * 3)
    val blendshapes = FloatArray(CameraKit.FACE_BLENDSHAPE_COUNT)

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
 * against. The buffer mirrors the frozen ck_lens_signals layout
 * (booleans and a reserved byte, then the padding to the first double
 * at offset 8, then blendshapes at offset 24) - absolute puts, not
 * relative, so this doesn't depend on writing the padding by hand. */
class LensSignals {
    internal val buffer: ByteBuffer =
        ByteBuffer.allocateDirect(CameraKit.LENS_SIGNALS_BYTES).order(java.nio.ByteOrder.nativeOrder())

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
        for (i in 0 until CameraKit.FACE_BLENDSHAPE_COUNT) {
            floats.put(6 + i, if (i < blendshapes.size) blendshapes[i] else 0f)
        }
    }
}

class Session private constructor(internal val handle: Long) : AutoCloseable {
    companion object {
        fun create(engine: Engine): Session {
            val handle = CameraKit.nativeSessionCreate(engine.handle)
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
        timestampUs: Long,
    ): Boolean = CameraKit.nativeSubmitFrameCopy(
        handle, y, yStride, uv, uvStride, width, height,
        CameraKit.flagsFor(rotationDegrees, mirrored),
        1, 0, timestampUs,
    ) == 0

    fun reportFrame(frameTimeUs: Int, thermal: Int): Int =
        CameraKit.nativeReportFrame(handle, frameTimeUs, thermal)

    fun enableFaceTracking(taskBundle: ByteBuffer): Boolean =
        CameraKit.nativeEnableFaceTracking(handle, taskBundle, taskBundle.remaining(), 0) == 0

    fun disableFaceTracking() = CameraKit.nativeDisableFaceTracking(handle)

    fun trackFrame(
        y: ByteBuffer,
        yStride: Int,
        uv: ByteBuffer,
        uvStride: Int,
        width: Int,
        height: Int,
        timestampUs: Long,
    ): Boolean = CameraKit.nativeTrackFrame(
        handle, y, yStride, uv, uvStride, width, height, 1, 0, timestampUs,
    ) == 0

    /** Stands the beauty chain up; [resourceDir] holds the effect engine's
     * shader and image assets on disk. */
    fun enableBeauty(resourceDir: String): Boolean {
        val bytes = resourceDir.toByteArray(Charsets.UTF_8)
        val buffer = ByteBuffer.allocateDirect(bytes.size + 1)
        buffer.put(bytes)
        buffer.put(0)
        buffer.rewind()
        return CameraKit.nativeEnableBeauty(handle, buffer, bytes.size) == 0
    }

    fun disableBeauty() = CameraKit.nativeDisableBeauty(handle)

    /** Effects in order: smooth 0, whiten 1, thin face 2, big eye 3,
     * lipstick 4, blush 5; values clamp to zero and one. */
    fun setBeauty(effect: Int, value: Float): Boolean =
        CameraKit.nativeSetBeauty(handle, effect, value) == 0

    fun beautifyFrame(rgbaIn: ByteBuffer, rgbaOut: ByteBuffer, width: Int, height: Int): Boolean =
        CameraKit.nativeBeautifyFrame(handle, rgbaIn, rgbaOut, width, height) == 0

    /** Fills [result] with the newest tracking output; false until the
     * worker publishes its first result. */
    fun faceResult(result: FaceResult): Boolean {
        val status = CameraKit.nativeFaceResult(handle, result.buffer)
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
        return CameraKit.nativeActivateLens(handle, buffer, manifestJson.size) == 0
    }

    fun deactivateLens() = CameraKit.nativeDeactivateLens(handle)

    /** Advances the active lens by [dtUs] of real time and applies
     * whatever effect values its triggers/ramps changed to the beauty
     * chain, if one is enabled. False with no active lens. */
    fun tickLens(dtUs: Int, signals: LensSignals): Boolean =
        CameraKit.nativeTickLens(handle, dtUs, signals.buffer) == 0

    fun submitHardwareBuffer(
        buffer: android.hardware.HardwareBuffer,
        width: Int,
        height: Int,
        rotationDegrees: Int,
        mirrored: Boolean,
        timestampUs: Long,
    ): Boolean = CameraKit.nativeSubmitHardwareBuffer(
        handle, buffer, width, height,
        CameraKit.flagsFor(rotationDegrees, mirrored),
        1, 0, timestampUs,
    ) == 0

    override fun close() = CameraKit.nativeSessionDestroy(handle)
}
