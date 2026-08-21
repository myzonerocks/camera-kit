package com.gosslens.demo

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer
import java.security.MessageDigest
import com.gosslens.GossEngine
import com.gosslens.Gosslens
import com.gosslens.GossSession

// Mirrors harness/conformance.zig's own determinism check (the same
// reference lens, the same corpus frame, rendered twice through the
// real ABI, byte-identical screenshots) but driven from the real Kotlin
// SDK instead of a desktop GLFW window - the same real
// GossEngine.initRenderer/GossSession.activateLens/GossEngine.renderFrame path
// MainActivity's live preview already runs, just fed a bundled corpus
// frame instead of the camera. Reached only behind the GossConformance
// intent extra; a normal launch never touches this file. Emulator
// output is a dev signal, not a substitute for a run on real hardware.
//
// Proves beauty-baseline, not just shader-tint: unlike the iOS
// Simulator (whose EAGLContext creation fails cleanly on recent
// runtimes - a real, root-caused platform gap, left open there), the
// Android emulator's GLES support is solid enough for gpupixel's own
// beauty chain to actually run, so this exercises the real row-6 GPU
// compositing bridge this session built, not just the lens-graph/bgfx
// half of the pipeline.
object ConformanceRunner {
    private const val TAG = "GOSSCONFORMANCE"

    fun run(context: Context, surface: Surface, width: Int, height: Int) {
        val corpus = loadCorpusNv12(context)
        if (corpus == null) {
            Log.e(TAG, "FAIL: corpus frame missing or undecodable")
            return
        }
        val pathA = File(context.cacheDir, "gossconformance-a").absolutePath
        val pathB = File(context.cacheDir, "gossconformance-b").absolutePath
        val hashA = renderOnce(context, surface, width, height, corpus, pathA)
        if (hashA == null) {
            Log.e(TAG, "FAIL: first render failed")
            return
        }
        val hashB = renderOnce(context, surface, width, height, corpus, pathB)
        if (hashB == null) {
            Log.e(TAG, "FAIL: second render failed")
            return
        }
        if (hashA == hashB) {
            Log.i(TAG, "PROOF beauty-baseline bit-stable sha256 $hashA")
        } else {
            Log.e(TAG, "FAIL non-deterministic: $hashA vs $hashB")
        }
    }

    private class Nv12Corpus(val width: Int, val height: Int, val y: ByteArray, val uv: ByteArray)

    // BT.601 full range, chroma averaged 2x2 - the same standard and
    // range harness/conformance.zig's own rgbaToNv12 uses on the same
    // corpus frame.
    private fun loadCorpusNv12(context: Context): Nv12Corpus? {
        val bitmap: Bitmap = try {
            context.assets.open("face_frontal_b.jpg").use { BitmapFactory.decodeStream(it) }
                ?: return null
        } catch (e: java.io.IOException) {
            return null
        }
        val width = bitmap.width
        val height = bitmap.height
        val argb = IntArray(width * height)
        bitmap.getPixels(argb, 0, width, 0, 0, width, height)

        fun toY(r: Double, g: Double, b: Double) = 0.299 * r + 0.587 * g + 0.114 * b
        fun toCb(r: Double, g: Double, b: Double) = -0.168736 * r - 0.331264 * g + 0.5 * b + 0.5
        fun toCr(r: Double, g: Double, b: Double) = 0.5 * r - 0.418688 * g - 0.081312 * b + 0.5
        fun toByte(v: Double) = (v.coerceIn(0.0, 1.0) * 255.0).toInt().toByte()

        val halfWidth = (width + 1) / 2
        val halfHeight = (height + 1) / 2
        val yPlane = ByteArray(width * height)
        val uvPlane = ByteArray(halfWidth * halfHeight * 2)

        for (row in 0 until height) {
            for (col in 0 until width) {
                val pixel = argb[row * width + col]
                val r = ((pixel shr 16) and 0xff) / 255.0
                val g = ((pixel shr 8) and 0xff) / 255.0
                val b = (pixel and 0xff) / 255.0
                yPlane[row * width + col] = toByte(toY(r, g, b))
            }
        }
        for (row in 0 until halfHeight) {
            for (col in 0 until halfWidth) {
                var cbSum = 0.0
                var crSum = 0.0
                var samples = 0.0
                for (dy in 0 until 2) {
                    for (dx in 0 until 2) {
                        val sourceY = row * 2 + dy
                        val sourceX = col * 2 + dx
                        if (sourceY >= height || sourceX >= width) continue
                        val pixel = argb[sourceY * width + sourceX]
                        val r = ((pixel shr 16) and 0xff) / 255.0
                        val g = ((pixel shr 8) and 0xff) / 255.0
                        val b = (pixel and 0xff) / 255.0
                        cbSum += toCb(r, g, b)
                        crSum += toCr(r, g, b)
                        samples += 1
                    }
                }
                val at = (row * halfWidth + col) * 2
                uvPlane[at] = toByte(cbSum / samples)
                uvPlane[at + 1] = toByte(crSum / samples)
            }
        }
        return Nv12Corpus(width, height, yPlane, uvPlane)
    }

    // Assets ship read-only inside the apk; the effects engine opens its
    // shader and lookup files with plain file i/o, so they need a real
    // extracted path - mirrors MainActivity's own extractBeautyResources,
    // small enough to keep as its own copy in this test-harness file
    // rather than plumb a shared helper through the live-preview path.
    private fun extractBeautyResources(context: Context): String? {
        val resDir = File(context.filesDir, "res")
        if (!resDir.exists()) {
            val names = try {
                context.assets.list("res")
            } catch (e: java.io.IOException) {
                null
            }
            if (names.isNullOrEmpty()) return null
            resDir.mkdirs()
            for (name in names) {
                context.assets.open("res/$name").use { input ->
                    File(resDir, name).outputStream().use { output -> input.copyTo(output) }
                }
            }
        }
        return context.filesDir.absolutePath
    }

    // A fresh engine/session per call, mirroring harness/conformance.zig's
    // own renderOnce - proves activation and teardown aren't hiding state
    // that would make a second run trivially match the first.
    private fun renderOnce(context: Context, surface: Surface, width: Int, height: Int, corpus: Nv12Corpus, outPath: String): String? {
        val engine = GossEngine.create()
        try {
            engine.initRenderer(surface, width, height)
            val session = GossSession.create(engine)
            try {
                val resourceRoot = extractBeautyResources(context) ?: return null
                if (!session.enableBeauty(resourceRoot)) return null
                session.setBeauty(0, 0.9f)
                session.setBeauty(1, 0.5f)

                val manifest = context.assets.open("lenses/beauty-baseline/manifest.json").use { it.readBytes() }
                if (!session.activateLens(manifest)) return null

                val yBuffer = ByteBuffer.allocateDirect(corpus.y.size).apply { put(corpus.y); rewind() }
                val uvBuffer = ByteBuffer.allocateDirect(corpus.uv.size).apply { put(corpus.uv); rewind() }
                val uvStride = ((corpus.width + 1) / 2) * 2
                val submitted = session.submitFrameCopy(
                    yBuffer, corpus.width, uvBuffer, uvStride,
                    corpus.width, corpus.height,
                    rotationDegrees = 0, mirrored = false,
                    colorStandard = Gosslens.COLOR_BT601, colorRange = Gosslens.RANGE_FULL,
                    timestampUs = 1000,
                )
                if (!submitted) return null

                repeat(5) { engine.renderFrame(session) }
                if (!engine.requestScreenshot(outPath)) return null
                repeat(5) { engine.renderFrame(session) }

                val shot = File("$outPath.tga")
                if (!shot.exists()) return null
                val digest = MessageDigest.getInstance("SHA-256").digest(shot.readBytes())
                return digest.joinToString("") { "%02x".format(it) }
            } finally {
                session.close()
            }
        } finally {
            engine.close()
        }
    }
}
