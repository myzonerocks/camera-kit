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
