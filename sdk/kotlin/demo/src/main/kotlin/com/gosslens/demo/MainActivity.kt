package com.gosslens.demo

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
import com.gosslens.Engine
import com.gosslens.FaceResult
import com.gosslens.LensSignals
import com.gosslens.Session
import java.nio.ByteBuffer
import java.util.concurrent.Executors

// Live capture through CameraX into the engine, rendered by the core onto
// the SurfaceView. NV12 planes go through the stated CPU copy path until the
// hardware buffer import lands; the frames, states, and fps in the log are
// the acceptance surface.
class MainActivity : AppCompatActivity(), SurfaceHolder.Callback {
    private val tag = "GOSSDROID"
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
    private val lensSignals = LensSignals()

    // Ring depth 2: submits hop to the main thread (bgfx's contract), so
    // the analyzer refills the next slot while the prior one is in
    // flight. With both slots pending it drops the frame rather than
    // overwrite a buffer a pending submit will still read.
    private val yScratchRing = arrayOfNulls<ByteBuffer>(2)
    private val uvScratchRing = arrayOfNulls<ByteBuffer>(2)
    private var scratchRingIndex = 0
    private val pendingCopySubmits = java.util.concurrent.atomic.AtomicInteger(0)

    // Zero-copy is attempted until the device or stream refuses it once;
    // after that the stream stays on the declared copy path. Written from
    // the main thread (inside the hopped submit below), read from the
    // analyzer thread.
    @Volatile
    private var zeroCopyRefused = false

    // One mirror decision for every consumer - both submit paths and the
    // face overlay - matching the front camera this demo binds below.
    // The preview must not flip depending on which submit path engaged.
    private val mirrorPreview = true

    // The conformance run reuses this same real window/renderer setup,
    // just feeding a fixed corpus frame instead of live camera - see
    // ConformanceRunner. Set via `am start --ez GossConformance true`, the
    // direct equivalent of the ios SDK's -GossConformance launch argument.
    private var conformanceMode = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        conformanceMode = intent.getBooleanExtra("GossConformance", false)
        val root = FrameLayout(this)
        surfaceView = SurfaceView(this)
        overlay = FaceOverlayView(this)
        root.addView(surfaceView)
        root.addView(overlay)
        if (!conformanceMode) setupBeautyControls(root)
        setContentView(root)
        surfaceView.holder.addCallback(this)

        if (!conformanceMode && ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
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
        if (conformanceMode) {
            ConformanceRunner.run(this, holder.surface, width, height)
            return
        }
        val created = Engine.create()
        created.initRenderer(holder.surface, width, height)
        engine = created
        val createdSession = Session.create(created)
        session = createdSession
        Log.i(tag, "renderer up ${width}x$height")
        try {
            assets.open("face_landmarker.task").use { stream ->
                val bytes = stream.readBytes()
                val bundle = ByteBuffer.allocateDirect(bytes.size)
                bundle.put(bytes)
                bundle.flip()
                if (createdSession.enableFaceTracking(bundle, 0)) {
                    Log.i(tag, "face tracking up")
                } else {
                    Log.i(tag, "face tracking unavailable in this build")
                }
            }
        } catch (e: java.io.IOException) {
            Log.i(tag, "face tracking bundle not present")
        }
        try {
            assets.open("hand_landmarker.task").use { stream ->
                val bytes = stream.readBytes()
                val bundle = ByteBuffer.allocateDirect(bytes.size)
                bundle.put(bytes)
                bundle.flip()
                if (createdSession.enableHandTracking(bundle, 0)) {
                    Log.i(tag, "hand tracking up")
                } else {
                    Log.i(tag, "hand tracking unavailable in this build")
                }
            }
        } catch (e: java.io.IOException) {
            Log.i(tag, "hand tracking bundle not present")
        }
        extractBeautyResources()?.let { resourceRoot ->
            if (createdSession.enableBeauty(resourceRoot)) {
                Log.i(tag, "beauty up")
            } else {
                Log.i(tag, "beauty unavailable in this build")
            }
        }
        try {
            assets.open("lenses/beauty-baseline/manifest.json").use { stream ->
                if (createdSession.activateLens(stream.readBytes())) {
                    Log.i(tag, "reference lens active")
                } else {
                    Log.i(tag, "reference lens activation refused")
                }
            }
        } catch (e: java.io.IOException) {
            Log.i(tag, "reference lens not present")
        }

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            startCamera()
        }
        Choreographer.getInstance().postFrameCallback(::renderTick)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        engine?.resize(width, height)
    }

    /** Rides the same result overlay.poll() just refreshed - ticking every
     * render frame regardless of whether that particular result was new
     * keeps the lens's own animation ramps advancing smoothly at display
     * refresh rate rather than at tracking cadence. */
    private fun tickLens(session: Session, dtUs: Int) {
        val hasFace = overlay.hasFaceResult &&
            overlay.latestFaceResult.presence >= 0.5f &&
            overlay.latestFaceResult.landmarkCount > 0
        lensSignals.set(hasFace, overlay.handCount > 0, false, 0.0, 0.0, overlay.latestFaceResult.blendshapes)
        session.tickLens(dtUs, lensSignals)
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

    // PowerManager's thermal statuses collapse onto the engine's four
    // levels the same way the ios demo maps ProcessInfo.thermalState.
    private fun thermalLevel(): Int {
        if (android.os.Build.VERSION.SDK_INT < 29) return 0
        val power = getSystemService(android.os.PowerManager::class.java) ?: return 0
        return when (power.currentThermalStatus) {
            android.os.PowerManager.THERMAL_STATUS_NONE -> 0
            android.os.PowerManager.THERMAL_STATUS_LIGHT -> 1
            android.os.PowerManager.THERMAL_STATUS_MODERATE -> 2
            else -> 3
        }
    }

    private fun renderTick(frameTimeNanos: Long) {
        val engine = engine ?: return
        val frameTimeUs = if (lastFrameNanos == 0L) 0 else ((frameTimeNanos - lastFrameNanos) / 1000).toInt()
        lastFrameNanos = frameTimeNanos
        session?.reportFrame(frameTimeUs, thermalLevel())
        session?.let { overlay.poll(it) }
        session?.let { tickLens(it, frameTimeUs) }
        if (engine.renderFrame(session)) {
            renderedFrames += 1
            fpsWindowFrames += 1
        }

        val now = System.nanoTime() / 1_000_000
        if (fpsWindowStart == 0L) fpsWindowStart = now
        if (now - fpsWindowStart >= 2000) {
            val fps = fpsWindowFrames * 1000.0 / (now - fpsWindowStart)
            Log.i(tag, "fps %.1f rendered %d camera %d".format(fps, renderedFrames, cameraFrames))
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
            val mainExecutor = ContextCompat.getMainExecutor(this)
            analysis.setAnalyzer(analysisExecutor) { image ->
                image.use {
                    val session = session ?: return@use

                    // bgfx runs on the main thread only; every submit below
                    // hops there, keeping its own frame data alive across
                    // the hop instead of relying on this analyzer callback's
                    // own buffers, which recycle once it returns.
                    var zeroCopyAttempted = false
                    if (!zeroCopyRefused && android.os.Build.VERSION.SDK_INT >= 28) {
                        val hardwareBuffer = it.image?.hardwareBuffer
                        if (hardwareBuffer != null) {
                            zeroCopyAttempted = true
                            val width = it.width
                            val height = it.height
                            val rotationDegrees = it.imageInfo.rotationDegrees
                            val timestampUs = it.imageInfo.timestamp / 1000
                            mainExecutor.execute {
                                val submitted = session.submitHardwareBuffer(
                                    hardwareBuffer,
                                    width, height,
                                    rotationDegrees, mirrorPreview,
                                    timestampUs = timestampUs,
                                )
                                hardwareBuffer.close()
                                if (submitted) {
                                    cameraFrames += 1
                                    if (cameraFrames == 1) Log.i(tag, "capture state running zero copy")
                                } else {
                                    zeroCopyRefused = true
                                    Log.i(tag, "zero copy refused, copy path takes over")
                                }
                            }
                        }
                    }

                    if (pendingCopySubmits.get() >= yScratchRing.size) return@use

                    val y = it.planes[0]
                    val u = it.planes[1]
                    val v = it.planes[2]

                    val slot = scratchRingIndex
                    scratchRingIndex = (scratchRingIndex + 1) % yScratchRing.size

                    val ySize = y.buffer.remaining()
                    var yCopy = yScratchRing[slot]
                    if (yCopy == null || yCopy.capacity() < ySize) {
                        yCopy = ByteBuffer.allocateDirect(ySize)
                        yScratchRing[slot] = yCopy
                    }
                    yCopy.clear()
                    yCopy.put(y.buffer)
                    yCopy.flip()

                    val uvStride: Int
                    var uvCopy = uvScratchRing[slot]
                    if (u.pixelStride == 2) {
                        // Semi-planar already; the interleaved view starts
                        // at the u plane.
                        val uvSize = u.buffer.remaining()
                        if (uvCopy == null || uvCopy.capacity() < uvSize) {
                            uvCopy = ByteBuffer.allocateDirect(uvSize)
                            uvScratchRing[slot] = uvCopy
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
                            uvScratchRing[slot] = uvCopy
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
                    if (!zeroCopyAttempted) {
                        val width = it.width
                        val height = it.height
                        val rotationDegrees = it.imageInfo.rotationDegrees
                        val timestampUs = it.imageInfo.timestamp / 1000
                        val yStride = y.rowStride
                        val ySubmit = yCopy
                        val uvSubmit = uvCopy
                        pendingCopySubmits.incrementAndGet()
                        mainExecutor.execute {
                            val submitted = session.submitFrameCopy(
                                ySubmit, yStride, uvSubmit, uvStride,
                                width, height,
                                rotationDegrees, mirrored = mirrorPreview,
                                timestampUs = timestampUs,
                            )
                            pendingCopySubmits.decrementAndGet()
                            if (submitted) {
                                cameraFrames += 1
                                if (cameraFrames == 1) Log.i(tag, "capture state running")
                            }
                        }
                    }
                    overlay.frameGeometry(it.width, it.height, it.imageInfo.rotationDegrees, mirrorPreview)
                    session.trackFrame(
                        yCopy, y.rowStride, uvCopy, uvStride,
                        it.width, it.height,
                        timestampUs = it.imageInfo.timestamp / 1000,
                    )
                }
            }
            provider.unbindAll()
            provider.bindToLifecycle(this, CameraSelector.DEFAULT_FRONT_CAMERA, analysis)
        }, ContextCompat.getMainExecutor(this))
    }
}
