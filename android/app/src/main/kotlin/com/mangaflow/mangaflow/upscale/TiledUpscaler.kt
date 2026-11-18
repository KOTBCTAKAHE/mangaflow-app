package com.mangaflow.mangaflow.upscale

import kotlin.math.max
import kotlin.math.min

/** One forward pass of an upscaling network on a single square tile (CHW, 0..1). */
fun interface TileModel {
    /** [input] is 3*size*size floats; returns 3*out*out floats, out = size*scale - 2*offset. */
    fun run(input: FloatArray, size: Int): FloatArray
}

/**
 * Geometry of a waifu2x-style model: output is [scale]x the input minus [offset]
 * pixels (output space) on each side; [tile] is the input tile edge, [blend] the
 * seam-blending width in output pixels.
 */
data class ModelSpec(val scale: Int, val offset: Int, val tile: Int, val blend: Int = 16)

class CancelledException : RuntimeException("cancelled")

/**
 * Tiled inference with cumulative seam blending (port of nunif/utils/seam_blending.py),
 * processed in horizontal bands so memory stays at one band of floats regardless of
 * page height (webtoon strips can be 10 000+ px tall).
 *
 * Input/output are ARGB ints. Finished output rows are handed to [sink] top to bottom.
 */
class TiledUpscaler(private val spec: ModelSpec, private val model: TileModel) {

    var tilesTotal = 0
        private set
    var tilesSkipped = 0
        private set

    fun process(
        pixels: IntArray,
        w: Int,
        h: Int,
        gray: Boolean,
        isCancelled: () -> Boolean = { false },
        sink: (rowStart: Int, rows: Int, data: IntArray) -> Unit,
    ) {
        val scale = spec.scale
        val tile = spec.tile
        val inOff = ceilDiv(spec.offset, scale)
        val inBlend = ceilDiv(spec.blend, scale)
        val step = tile - (2 * inOff + inBlend)
        require(step > 0) { "tile too small" }
        val hb = blocks(h, inOff, tile, step)
        val wb = blocks(w, inOff, tile, step)
        val pw = (wb - 1) * step + tile
        val tout = tile * scale - 2 * spec.offset
        val sout = step * scale
        val ow = w * scale
        val oh = h * scale
        val bandW = pw * scale

        val ramp = FloatArray(tout) { x ->
            min(1f, min((x + 1f) / (spec.blend + 1f), (tout - x).toFloat() / (spec.blend + 1f)))
        }
        val band = FloatArray(3 * tout * bandW)
        val weight = FloatArray(tout * bandW)
        val input = FloatArray(3 * tile * tile)
        val plane = tout * bandW
        val tilePlane = tile * tile
        val outPlane = tout * tout
        tilesTotal = hb * wb
        tilesSkipped = 0

        for (i in 0 until hb) {
            for (j in 0 until wb) {
                if (isCancelled()) throw CancelledException()
                // Gather the tile with replication padding (clamped coordinates).
                var minR = 255; var maxR = 0; var minG = 255; var maxG = 0; var minB = 255; var maxB = 0
                var sumR = 0L; var sumG = 0L; var sumB = 0L
                for (yy in 0 until tile) {
                    val sy = (i * step + yy - inOff).coerceIn(0, h - 1)
                    val rowBase = sy * w
                    val o = yy * tile
                    for (xx in 0 until tile) {
                        val sx = (j * step + xx - inOff).coerceIn(0, w - 1)
                        val p = pixels[rowBase + sx]
                        val r = (p shr 16) and 0xFF
                        val g = (p shr 8) and 0xFF
                        val b = p and 0xFF
                        if (r < minR) minR = r; if (r > maxR) maxR = r
                        if (g < minG) minG = g; if (g > maxG) maxG = g
                        if (b < minB) minB = b; if (b > maxB) maxB = b
                        sumR += r; sumG += g; sumB += b
                        input[o + xx] = r / 255f
                        input[tilePlane + o + xx] = g / 255f
                        input[2 * tilePlane + o + xx] = b / 255f
                    }
                }
                val y: FloatArray
                if (maxR - minR <= FLAT && maxG - minG <= FLAT && maxB - minB <= FLAT) {
                    // Flat tile (page margins, gutters, solid fills): no inference needed.
                    tilesSkipped++
                    val n = tilePlane.toFloat() * 255f
                    y = FloatArray(3 * outPlane)
                    y.fill(sumR / n, 0, outPlane)
                    y.fill(sumG / n, outPlane, 2 * outPlane)
                    y.fill(sumB / n, 2 * outPlane, 3 * outPlane)
                } else {
                    y = model.run(input, tile)
                    require(y.size == 3 * outPlane) { "model output ${y.size} != ${3 * outPlane}" }
                }
                // Accumulate with seam-blending weights.
                val x0 = j * sout
                for (yy in 0 until tout) {
                    val ry = ramp[yy]
                    val bRow = yy * bandW + x0
                    val tRow = yy * tout
                    for (xx in 0 until tout) {
                        val wv = ry * ramp[xx]
                        val bi = bRow + xx
                        val ti = tRow + xx
                        band[bi] += y[ti] * wv
                        band[plane + bi] += y[outPlane + ti] * wv
                        band[2 * plane + bi] += y[2 * outPlane + ti] * wv
                        weight[bi] += wv
                    }
                }
            }
            // Rows above the next tile row are final.
            val rows = if (i < hb - 1) sout else tout
            val r0 = i * sout
            val n = min(rows, oh - r0)
            if (n > 0) {
                val data = IntArray(n * ow)
                for (yy in 0 until n) {
                    val bRow = yy * bandW
                    val dRow = yy * ow
                    for (xx in 0 until ow) {
                        val bi = bRow + xx
                        val wv = max(weight[bi], 1e-6f)
                        var r = band[bi] / wv
                        var g = band[plane + bi] / wv
                        var b = band[2 * plane + bi] / wv
                        if (gray) {
                            val l = (r + g + b) / 3f
                            r = l; g = l; b = l
                        }
                        data[dRow + xx] = (0xFF shl 24) or (to8(r) shl 16) or (to8(g) shl 8) or to8(b)
                    }
                }
                sink(r0, n, data)
            }
            // Slide the overlap to the top of the band.
            val keep = tout - sout
            if (keep > 0 && i < hb - 1) {
                for (c in 0 until 3) {
                    System.arraycopy(band, c * plane + sout * bandW, band, c * plane, keep * bandW)
                    band.fill(0f, c * plane + keep * bandW, (c + 1) * plane)
                }
                System.arraycopy(weight, sout * bandW, weight, 0, keep * bandW)
                weight.fill(0f, keep * bandW, plane)
            }
        }
    }

    companion object {
        /** Max channel spread (0..255) for a tile to count as flat. */
        const val FLAT = 2

        fun ceilDiv(a: Int, b: Int) = (a + b - 1) / b

        fun blocks(size: Int, inOff: Int, tile: Int, step: Int): Int =
            if (size + 2 * inOff > tile) ceilDiv(size + 2 * inOff - tile, step) + 1 else 1

        private fun to8(v: Float): Int = (v * 255f + 0.5f).toInt().coerceIn(0, 255)

        /** True when (almost) every sampled pixel has R≈G≈B — typical B/W manga. */
        fun isGrayscale(pixels: IntArray, tolerance: Int = 10, sampleStep: Int = 7): Boolean {
            var colored = 0
            var total = 0
            var k = 0
            while (k < pixels.size) {
                val p = pixels[k]
                val r = (p shr 16) and 0xFF
                val g = (p shr 8) and 0xFF
                val b = p and 0xFF
                if (kotlin.math.abs(r - g) > tolerance || kotlin.math.abs(g - b) > tolerance || kotlin.math.abs(r - b) > tolerance) colored++
                total++
                k += sampleStep
            }
            return total > 0 && colored <= total / 500
        }
    }
}
