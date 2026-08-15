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

    /** Fills [result] with the newest tracking output; false until the
     * worker publishes its first result. */
    fun faceResult(result: FaceResult): Boolean {
        val status = CameraKit.nativeFaceResult(handle, result.buffer)
        if (status != 0) return false
        result.parse()
        return true
    }

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
