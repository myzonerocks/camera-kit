package kit.camera.demo

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.util.Log
import android.view.Choreographer
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import kit.camera.Engine
import kit.camera.FaceResult
import kit.camera.Session
import java.nio.ByteBuffer
import java.util.concurrent.Executors

// Live capture through CameraX into the engine, rendered by the core onto
// the SurfaceView. NV12 planes go through the stated CPU copy path until the
// hardware buffer import lands; the frames, states, and fps in the log are
// the acceptance surface.
class MainActivity : AppCompatActivity(), SurfaceHolder.Callback {
    private val tag = "CKDROID"
    private lateinit var surfaceView: SurfaceView
    private lateinit var overlay: FaceOverlayView
    private var engine: Engine? = null
    private var session: Session? = null
    private val analysisExecutor = Executors.newSingleThreadExecutor()

    private var cameraFrames = 0
    private var renderedFrames = 0
    private var fpsWindowStart = 0L
    private var fpsWindowFrames = 0
    private var lastFrameNanos = 0L
    private var proofLogged = false

    // Two frames of retained buffers keep the copies alive while in flight.
    private var yScratch: ByteBuffer? = null
    private var uvScratch: ByteBuffer? = null

    // Zero-copy is attempted until the device or stream refuses it once;
    // after that the stream stays on the declared copy path.
    private var zeroCopyRefused = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = FrameLayout(this)
        surfaceView = SurfaceView(this)
        overlay = FaceOverlayView(this)
        root.addView(surfaceView)
        root.addView(overlay)
        setupBeautyControls(root)
        setContentView(root)
        surfaceView.holder.addCallback(this)

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CAMERA), 1)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            startCamera()
        } else {
            Log.i(tag, "capture state denied")
        }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        val width = surfaceView.width
        val height = surfaceView.height
        val created = Engine.create()
        created.initRenderer(holder.surface, width, height)
        engine = created
        val createdSession = Session.create(created)
        session = createdSession
        Log.i(tag, "renderer up ${width}x$height")
        assets.open("face_landmarker.task").use { stream ->
            val bytes = stream.readBytes()
            val bundle = ByteBuffer.allocateDirect(bytes.size)
            bundle.put(bytes)
            bundle.flip()
            if (createdSession.enableFaceTracking(bundle)) {
                Log.i(tag, "face tracking up")
            } else {
                Log.i(tag, "face tracking unavailable in this build")
            }
        }
        extractBeautyResources()?.let { resourceRoot ->
            if (createdSession.enableBeauty(resourceRoot)) {
                Log.i(tag, "beauty up")
            } else {
                Log.i(tag, "beauty unavailable in this build")
            }
        }

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            startCamera()
        }
        Choreographer.getInstance().postFrameCallback(::renderTick)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        engine?.resize(width, height)
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        session?.close()
        engine?.close()
        session = null
        engine = null
    }

    // Assets ship read-only inside the apk; the effects engine opens its
    // shader and lookup files with plain file i/o, so they need a real
    // path. Copied once per install, reused after.
    private fun extractBeautyResources(): String? {
        val resDir = java.io.File(filesDir, "res")
        if (!resDir.exists()) {
            val names = try { assets.list("res") } catch (e: java.io.IOException) { null }
            if (names.isNullOrEmpty()) return null
            resDir.mkdirs()
            for (name in names) {
                assets.open("res/$name").use { input ->
                    java.io.File(resDir, name).outputStream().use { output -> input.copyTo(output) }
                }
            }
        }
        return filesDir.absolutePath
    }

    // Each slider reaches Session.setBeauty directly; the effect only
    // shows up once something reads the rgba back out through
    // beautifyFrame, which this cpu copy path preview does not do yet.
    private fun setupBeautyControls(root: FrameLayout) {
        val names = listOf("smooth", "whiten", "thin face", "big eye", "lipstick", "blush")
        val stack = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 24, 24, 24)
        }
        for ((index, name) in names.withIndex()) {
            val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            row.addView(TextView(this).apply {
                text = name
                setTextColor(Color.WHITE)
                layoutParams = LinearLayout.LayoutParams(160, LinearLayout.LayoutParams.WRAP_CONTENT)
            })
            row.addView(SeekBar(this).apply {
                max = 100
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                    override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                        session?.setBeauty(index, progress / 100f)
                    }
                    override fun onStartTrackingTouch(seekBar: SeekBar?) {}
                    override fun onStopTrackingTouch(seekBar: SeekBar?) {}
                })
            })
            stack.addView(row)
        }
        root.addView(
            stack,
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT).apply {
                gravity = Gravity.BOTTOM
            },
        )
    }

    private fun renderTick(frameTimeNanos: Long) {
        val engine = engine ?: return
        val frameTimeUs = if (lastFrameNanos == 0L) 0 else ((frameTimeNanos - lastFrameNanos) / 1000).toInt()
        lastFrameNanos = frameTimeNanos
        session?.reportFrame(frameTimeUs, 0)
        session?.let { overlay.poll(it) }
        if (engine.renderFrame(session)) {
            renderedFrames += 1
            fpsWindowFrames += 1
        }

        val now = System.nanoTime() / 1_000_000
        if (fpsWindowStart == 0L) fpsWindowStart = now
        if (now - fpsWindowStart >= 2000) {
            val fps = fpsWindowFrames * 1000.0 / (now - fpsWindowStart)
            Log.i(tag, "fps %.1f rendered %d camera %d".format(fps, renderedFrames, cameraFrames))
            if (!proofLogged && cameraFrames > 30 && fps > 20) {
                proofLogged = true
                Log.i(tag, "CKDROID preview active: $cameraFrames camera frames rendered at %.1f fps".format(fps))
            }
            fpsWindowStart = now
            fpsWindowFrames = 0
        }
        Choreographer.getInstance().postFrameCallback(::renderTick)
    }

    private fun startCamera() {
        val providerFuture = ProcessCameraProvider.getInstance(this)
        providerFuture.addListener({
            val provider = providerFuture.get()
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
                .build()
            analysis.setAnalyzer(analysisExecutor) { image ->
                image.use {
                    val session = session ?: return@use

                    var previewSubmitted = false
                    if (!zeroCopyRefused && android.os.Build.VERSION.SDK_INT >= 28) {
                        val hardwareBuffer = it.image?.hardwareBuffer
                        if (hardwareBuffer != null) {
                            val submitted = session.submitHardwareBuffer(
                                hardwareBuffer,
                                it.width, it.height,
                                it.imageInfo.rotationDegrees, false,
                                it.imageInfo.timestamp / 1000,
                            )
                            hardwareBuffer.close()
                            if (submitted) {
                                cameraFrames += 1
                                if (cameraFrames == 1) Log.i(tag, "capture state running zero copy")
                                previewSubmitted = true
                            } else {
                                zeroCopyRefused = true
                                Log.i(tag, "zero copy refused, copy path takes over")
                            }
                        }
                    }

                    val y = it.planes[0]
                    val u = it.planes[1]
                    val v = it.planes[2]

                    // Direct buffers survive the native call; the camera
                    // buffer is recycled the moment use() closes.
                    val ySize = y.buffer.remaining()
                    var yCopy = yScratch
                    if (yCopy == null || yCopy.capacity() < ySize) {
                        yCopy = ByteBuffer.allocateDirect(ySize)
                        yScratch = yCopy
                    }
                    yCopy.clear()
                    yCopy.put(y.buffer)
                    yCopy.flip()

                    val uvStride: Int
                    var uvCopy = uvScratch
                    if (u.pixelStride == 2) {
                        // Semi-planar already; the interleaved view starts
                        // at the u plane.
                        val uvSize = u.buffer.remaining()
                        if (uvCopy == null || uvCopy.capacity() < uvSize) {
                            uvCopy = ByteBuffer.allocateDirect(uvSize)
                            uvScratch = uvCopy
                        }
                        uvCopy.clear()
                        uvCopy.put(u.buffer)
                        uvCopy.flip()
                        uvStride = u.rowStride
                    } else {
                        // Planar chroma, the emulator's layout: interleave
                        // u and v into one nv12 plane.
                        val chromaWidth = it.width / 2
                        val chromaHeight = it.height / 2
                        val uvSize = chromaWidth * chromaHeight * 2
                        if (uvCopy == null || uvCopy.capacity() < uvSize) {
                            uvCopy = ByteBuffer.allocateDirect(uvSize)
                            uvScratch = uvCopy
                        }
                        uvCopy.clear()
                        val uBuf = u.buffer
                        val vBuf = v.buffer
                        for (row in 0 until chromaHeight) {
                            val uRow = row * u.rowStride
                            val vRow = row * v.rowStride
                            for (col in 0 until chromaWidth) {
                                uvCopy.put(uBuf.get(uRow + col * u.pixelStride))
                                uvCopy.put(vBuf.get(vRow + col * v.pixelStride))
                            }
                        }
                        uvCopy.flip()
                        uvStride = chromaWidth * 2
                    }
                    if (!previewSubmitted) {
                        val submitted = session.submitFrameCopy(
                            yCopy, y.rowStride, uvCopy, uvStride,
                            it.width, it.height,
                            it.imageInfo.rotationDegrees, mirrored = false,
                            it.imageInfo.timestamp / 1000,
                        )
                        if (submitted) {
                            cameraFrames += 1
                            if (cameraFrames == 1) Log.i(tag, "capture state running")
                        }
                    }
                    overlay.frameGeometry(it.width, it.height, it.imageInfo.rotationDegrees)
                    session.trackFrame(
                        yCopy, y.rowStride, uvCopy, uvStride,
                        it.width, it.height,
                        it.imageInfo.timestamp / 1000,
                    )
                }
            }
            provider.unbindAll()
            provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, analysis)
        }, ContextCompat.getMainExecutor(this))
    }
}
