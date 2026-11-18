package com.mangaflow.mangaflow.upscale

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/**
 * The tiling/blending engine must be exact: with a "model" that is a plain nearest-neighbour
 * 2x (cropped by `offset` like waifu2x), the stitched output has to equal a global
 * nearest-neighbour upscale — any seam, off-by-one or band bug shows up as a mismatch.
 */
class TiledUpscalerTest {

    private fun nearestModel(spec: ModelSpec, calls: IntArray? = null) = TileModel { input, size ->
        calls?.let { it[0]++ }
        val out = size * spec.scale - 2 * spec.offset
        val plane = size * size
        val o = FloatArray(3 * out * out)
        for (c in 0 until 3) for (y in 0 until out) for (x in 0 until out) {
            val sy = (y + spec.offset) / spec.scale
            val sx = (x + spec.offset) / spec.scale
            o[c * out * out + y * out + x] = input[c * plane + sy * size + sx]
        }
        o
    }

    private fun nearest2x(px: IntArray, w: Int, h: Int, s: Int): IntArray {
        val o = IntArray(w * s * h * s)
        for (y in 0 until h * s) for (x in 0 until w * s) o[y * w * s + x] = px[(y / s) * w + x / s]
        return o
    }

    private fun run(spec: ModelSpec, px: IntArray, w: Int, h: Int, gray: Boolean = false, calls: IntArray? = null): IntArray {
        val ow = w * spec.scale
        val out = IntArray(ow * h * spec.scale)
        var next = 0
        TiledUpscaler(spec, nearestModel(spec, calls)).process(px, w, h, gray) { r0, rows, data ->
            assertEquals("rows must arrive in order without gaps", next, r0)
            System.arraycopy(data, 0, out, r0 * ow, rows * ow)
            next = r0 + rows
        }
        assertEquals(h * spec.scale, next)
        return out
    }

    private fun noise(w: Int, h: Int, seed: Int) = Random(seed).let { r ->
        IntArray(w * h) { (0xFF shl 24) or r.nextInt(0x1000000) }
    }

    @Test fun cunetGeometry_exactOnOddSizes() {
        val spec = ModelSpec(scale = 2, offset = 36, tile = 196)
        for ((w, h) in listOf(1 to 1, 37 to 53, 196 to 196, 301 to 157, 640 to 1031)) {
            val px = noise(w, h, w * 31 + h)
            assertArrayEquals("size ${w}x$h", nearest2x(px, w, h, 2), run(spec, px, w, h))
        }
    }

    @Test fun swinGeometry_exact() {
        val spec = ModelSpec(scale = 2, offset = 16, tile = 160)
        val (w, h) = 333 to 777
        val px = noise(w, h, 7)
        assertArrayEquals(nearest2x(px, w, h, 2), run(spec, px, w, h))
    }

    @Test fun flatTilesSkipInference() {
        val spec = ModelSpec(scale = 2, offset = 36, tile = 196)
        val (w, h) = 500 to 900
        val px = IntArray(w * h) { 0xFFFFFFFF.toInt() } // blank page
        px[450 * w + 250] = 0xFF000000.toInt() // one ink dot
        val calls = intArrayOf(0)
        val out = run(spec, px, w, h, calls = calls)
        assertArrayEquals(nearest2x(px, w, h, 2), out)
        assertTrue("only tiles touching the dot run the model (${calls[0]})", calls[0] in 1..4)
    }

    @Test fun grayModeRemovesTint() {
        val spec = ModelSpec(scale = 2, offset = 36, tile = 196)
        val px = intArrayOf(0xFF102030.toInt(), 0xFF808080.toInt(), 0xFF000000.toInt(), 0xFFFFFFFF.toInt())
        val out = run(spec, px, 2, 2, gray = true)
        for (p in out) {
            val r = (p shr 16) and 0xFF; val g = (p shr 8) and 0xFF; val b = p and 0xFF
            assertTrue(r == g && g == b)
        }
        assertEquals(0x20, out[0] and 0xFF) // (16+32+48)/3
    }

    @Test fun grayscaleDetection() {
        val bw = IntArray(10_000) { if (it % 3 == 0) 0xFF000000.toInt() else 0xFFF4F4F2.toInt() }
        assertTrue(TiledUpscaler.isGrayscale(bw))
        val color = IntArray(10_000) { if (it % 2 == 0) 0xFFFF2020.toInt() else 0xFFFFFFFF.toInt() }
        assertFalse(TiledUpscaler.isGrayscale(color))
    }

    @Test(expected = CancelledException::class)
    fun cancellationStopsBetweenTiles() {
        val spec = ModelSpec(scale = 2, offset = 36, tile = 196)
        var n = 0
        TiledUpscaler(spec, nearestModel(spec)).process(noise(600, 600, 1), 600, 600, false, isCancelled = { ++n > 2 }) { _, _, _ -> }
    }
}
