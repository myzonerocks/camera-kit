package kit.camera.demo

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.View
import kit.camera.FaceResult
import kit.camera.Session

/** Draws the latest tracking result over the preview. Landmarks arrive in
 * sensor pixels; the view rotates them by the frame's quarter turns and
 * scales into its own bounds, the same mapping the preview quad uses. */
class FaceOverlayView(context: Context) : View(context) {
    private val result = FaceResult()
    private var hasResult = false
    private var lastSerial = 0L

    /** The latest polled result and whether one has ever arrived - read
     * by MainActivity to drive the active lens's face-present signal. */
    val latestFaceResult: FaceResult get() = result
    val hasFaceResult: Boolean get() = hasResult

    private var frameWidth = 0
    private var frameHeight = 0
    private var rotationDegrees = 0

    private val pointPaint = Paint().apply {
        color = Color.WHITE
        strokeWidth = 3f
        strokeCap = Paint.Cap.ROUND
    }
    private val points = FloatArray(kit.camera.CameraKit.FACE_LANDMARK_COUNT * 2)

    fun frameGeometry(width: Int, height: Int, rotation: Int) {
        frameWidth = width
        frameHeight = height
        rotationDegrees = rotation
    }

    /** Called once per render tick from the choreographer thread. */
    fun poll(session: Session) {
        if (!session.faceResult(result)) return
        if (result.frameSerial == lastSerial) return
        lastSerial = result.frameSerial
        hasResult = true
        postInvalidateOnAnimation()
    }

    override fun onDraw(canvas: Canvas) {
        if (!hasResult || frameWidth == 0) return
        if (result.landmarkCount == 0 || result.presence < 0.5f) return

        val quarterTurns = ((rotationDegrees % 360) / 90) and 0x3
        val rotatedWidth = if (quarterTurns % 2 == 1) frameHeight else frameWidth
        val rotatedHeight = if (quarterTurns % 2 == 1) frameWidth else frameHeight
        val scaleX = width.toFloat() / rotatedWidth
        val scaleY = height.toFloat() / rotatedHeight

        var write = 0
        for (index in 0 until result.landmarkCount) {
            val x = result.landmarks[index * 3]
            val y = result.landmarks[index * 3 + 1]
            val rotatedX: Float
            val rotatedY: Float
            when (quarterTurns) {
                1 -> { rotatedX = frameHeight - y; rotatedY = x }
                2 -> { rotatedX = frameWidth - x; rotatedY = frameHeight - y }
                3 -> { rotatedX = y; rotatedY = frameWidth - x }
                else -> { rotatedX = x; rotatedY = y }
            }
            points[write] = rotatedX * scaleX
            points[write + 1] = rotatedY * scaleY
            write += 2
        }
        canvas.drawPoints(points, 0, write, pointPaint)
    }
}
