package com.gosslens.demo

import com.google.ar.core.Camera
import com.google.ar.core.Frame
import com.google.ar.core.Plane
import com.google.ar.core.TrackingState
import com.gosslens.Gosslens
import com.gosslens.Session
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Feeds ARCore's world understanding into the engine: camera pose and
 * projection, tracked planes, anchors, and the light estimate, one
 * submit per ARCore frame. The activity owns the ARCore session; this
 * feeder only reads its frames. */
class WorldFeeder(private val session: Session) {
    private val stateBuffer = ByteBuffer.allocateDirect(144).order(ByteOrder.nativeOrder())
    private val lightBuffer = ByteBuffer.allocateDirect(8).order(ByteOrder.nativeOrder())
    private var planesBuffer = ByteBuffer.allocateDirect(88 * 8).order(ByteOrder.nativeOrder())
    private var anchorsBuffer = ByteBuffer.allocateDirect(72 * 8).order(ByteOrder.nativeOrder())
    private val matrix = FloatArray(16)

    fun onFrame(frame: Frame) {
        val camera: Camera = frame.camera
        stateBuffer.clear()
        stateBuffer.putInt(trackingState(camera.trackingState))
        camera.displayOrientedPose.toMatrix(matrix, 0)
        for (value in matrix) stateBuffer.putFloat(value)
        camera.getProjectionMatrix(matrix, 0, 0.1f, 100f)
        for (value in matrix) stateBuffer.putFloat(value)
        stateBuffer.putInt(0) // padding to the 8-aligned timestamp
        stateBuffer.putLong(frame.timestamp / 1_000)

        val planes = frame.getUpdatedTrackables(Plane::class.java)
            .filter { it.trackingState == TrackingState.TRACKING }
        ensurePlaneCapacity(planes.size)
        planesBuffer.clear()
        for (plane in planes) {
            planesBuffer.putLong(plane.hashCode().toLong())
            plane.centerPose.toMatrix(matrix, 0)
            for (value in matrix) planesBuffer.putFloat(value)
            planesBuffer.putFloat(plane.extentX)
            planesBuffer.putFloat(plane.extentZ)
            planesBuffer.putInt(planeClass(plane.type))
            planesBuffer.putInt(0) // padding to the 8-aligned stride
        }

        val anchors = session.let { frame.updatedAnchors }
            .filter { it.trackingState == TrackingState.TRACKING }
        ensureAnchorCapacity(anchors.size)
        anchorsBuffer.clear()
        for (anchor in anchors) {
            anchorsBuffer.putLong(anchor.hashCode().toLong())
            anchor.pose.toMatrix(matrix, 0)
            for (value in matrix) anchorsBuffer.putFloat(value)
        }

        lightBuffer.clear()
        lightBuffer.putFloat(frame.lightEstimate.pixelIntensity)
        lightBuffer.putFloat(0f)

        Gosslens.nativeSubmitWorld(
            session.handle, stateBuffer, planesBuffer, planes.size,
            anchorsBuffer, anchors.size, lightBuffer,
        )
    }

    private fun trackingState(state: TrackingState): Int = when (state) {
        TrackingState.TRACKING -> 2
        TrackingState.PAUSED -> 3
        TrackingState.STOPPED -> 0
    }

    private fun planeClass(type: Plane.Type): Int = when (type) {
        Plane.Type.HORIZONTAL_UPWARD_FACING -> 1
        Plane.Type.VERTICAL -> 2
        Plane.Type.HORIZONTAL_DOWNWARD_FACING -> 3
    }

    private fun ensurePlaneCapacity(count: Int) {
        if (planesBuffer.capacity() < count * 88) {
            planesBuffer = ByteBuffer.allocateDirect(count * 88).order(ByteOrder.nativeOrder())
        }
    }

    private fun ensureAnchorCapacity(count: Int) {
        if (anchorsBuffer.capacity() < count * 72) {
            anchorsBuffer = ByteBuffer.allocateDirect(count * 72).order(ByteOrder.nativeOrder())
        }
    }
}
