package com.gosslens.demo

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.View
import com.gosslens.GossFaceResult
import com.gosslens.GossHandResult
import com.gosslens.GossPoseResult
import com.gosslens.GossSession

/** Draws the latest tracking result over the preview. Landmarks arrive in
 * sensor pixels; the view rotates them by the frame's quarter turns and
 * scales into its own bounds, the same mapping the preview quad uses. */
class FaceOverlayView(context: Context) : View(context) {
    private val result = GossFaceResult()
    private var hasResult = false
    private var lastSerial = 0L

    /** The latest polled result and whether one has ever arrived - read
     * by MainActivity to drive the active lens's face-present signal. */
    val latestFaceResult: GossFaceResult get() = result
    val hasFaceResult: Boolean get() = hasResult

    private val hands = GossHandResult()
    private var lastHandSerial = 0L

    /** Read by MainActivity to drive the lens's hands-present signal. */
    val handCount: Int get() = hands.handCount

    private val body = GossPoseResult()
    private var lastPoseSerial = 0L

    private var frameWidth = 0
    private var frameHeight = 0
    private var rotationDegrees = 0
    private var mirrored = false

    private val pointPaint = Paint().apply {
        color = Color.WHITE
        strokeWidth = 3f
        strokeCap = Paint.Cap.ROUND
    }
    private val points = FloatArray(com.gosslens.Gosslens.FACE_LANDMARK_COUNT * 2)
    private val handPoints = FloatArray(com.gosslens.Gosslens.HAND_MAX * com.gosslens.Gosslens.HAND_LANDMARK_COUNT * 2)
    private val posePoints = FloatArray(com.gosslens.Gosslens.POSE_LANDMARK_COUNT * 2)

    fun frameGeometry(width: Int, height: Int, rotation: Int, mirror: Boolean) {
        frameWidth = width
        frameHeight = height
        rotationDegrees = rotation
        mirrored = mirror
    }

    /** Called once per render tick from the choreographer thread. */
    fun poll(session: GossSession) {
        var fresh = false
        if (session.faceResult(result) && result.frameSerial != lastSerial) {
            lastSerial = result.frameSerial
            hasResult = true
            fresh = true
        }
        if (session.handResult(hands) && hands.frameSerial != lastHandSerial) {
            lastHandSerial = hands.frameSerial
            fresh = true
        }
        if (session.poseResult(body) && body.frameSerial != lastPoseSerial) {
            lastPoseSerial = body.frameSerial
            fresh = true
        }
        if (fresh) postInvalidateOnAnimation()
    }

    private fun mapPoint(x: Float, y: Float, quarterTurns: Int, scaleX: Float, scaleY: Float, out: FloatArray, write: Int) {
        val rotatedX: Float
        val rotatedY: Float
        when (quarterTurns) {
            1 -> { rotatedX = frameHeight - y; rotatedY = x }
            2 -> { rotatedX = frameWidth - x; rotatedY = frameHeight - y }
            3 -> { rotatedX = y; rotatedY = frameWidth - x }
            else -> { rotatedX = x; rotatedY = y }
        }
        // Landmarks are raw sensor space; a mirrored preview flips its
        // horizontal axis, so the overlay flips with it.
        out[write] = if (mirrored) width - rotatedX * scaleX else rotatedX * scaleX
        out[write + 1] = rotatedY * scaleY
    }

    override fun onDraw(canvas: Canvas) {
        if (frameWidth == 0) return
        val quarterTurns = ((rotationDegrees % 360) / 90) and 0x3
        val rotatedWidth = if (quarterTurns % 2 == 1) frameHeight else frameWidth
        val rotatedHeight = if (quarterTurns % 2 == 1) frameWidth else frameHeight
        val scaleX = width.toFloat() / rotatedWidth
        val scaleY = height.toFloat() / rotatedHeight

        if (hasResult && result.landmarkCount > 0 && result.presence >= 0.5f) {
            var write = 0
            for (index in 0 until result.landmarkCount) {
                mapPoint(result.landmarks[index * 3], result.landmarks[index * 3 + 1], quarterTurns, scaleX, scaleY, points, write)
                write += 2
            }
            canvas.drawPoints(points, 0, write, pointPaint)
        }

        if (hands.handCount > 0) {
            var write = 0
            for (handAt in 0 until hands.handCount) {
                val base = handAt * com.gosslens.Gosslens.HAND_LANDMARK_COUNT * 3
                for (point in 0 until com.gosslens.Gosslens.HAND_LANDMARK_COUNT) {
                    mapPoint(hands.landmarks[base + point * 3], hands.landmarks[base + point * 3 + 1], quarterTurns, scaleX, scaleY, handPoints, write)
                    write += 2
                }
            }
            canvas.drawPoints(handPoints, 0, write, pointPaint)
        }

        if (body.landmarkCount > 0 && body.presence >= 0.5f) {
            var write = 0
            for (point in 0 until body.landmarkCount) {
                if (body.visibilities[point] < 0.5f) continue
                mapPoint(body.landmarks[point * 3], body.landmarks[point * 3 + 1], quarterTurns, scaleX, scaleY, posePoints, write)
                write += 2
            }
            canvas.drawPoints(posePoints, 0, write, pointPaint)
        }
    }
}
