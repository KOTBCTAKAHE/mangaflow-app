package com.mangaflow.mangaflow

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.FilterInputStream
import java.io.InputStream
import java.io.RandomAccessFile
import java.nio.channels.FileChannel
import java.security.MessageDigest
import java.util.zip.Inflater
import java.util.zip.InflaterInputStream

/**
 * Over-the-air updates with small delta patches (MFDELTA1 = bsdiff blocks, each zlib-compressed;
 * made in CI by tool/mfdelta.py). Rebuilds the new APK from the installed one, streaming:
 * the old APK is memory-mapped, the diff/extra blocks are inflated on the fly.
 */
object OtaUpdater {
    private val MAGIC = "MFDELTA1".toByteArray()

    fun sha256(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buf = ByteArray(1 shl 16)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun le64(b: ByteArray, off: Int): Long {
        var v = 0L
        for (i in 7 downTo 0) v = (v shl 8) or (b[off + i].toLong() and 0xff)
        return v
    }

    /** bsdiff's sign-magnitude int64. */
    private fun offtin(b: ByteArray, off: Int): Long {
        var y = (b[off + 7].toLong() and 0x7f)
        for (i in 6 downTo 0) y = y * 256 + (b[off + i].toLong() and 0xff)
        return if (b[off + 7].toInt() and 0x80 != 0) -y else y
    }

    private class Limited(input: InputStream, private var left: Long) : FilterInputStream(input) {
        override fun read(): Int {
            if (left <= 0) return -1
            val r = super.read()
            if (r >= 0) left--
            return r
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (left <= 0) return -1
            val n = super.read(b, off, minOf(len.toLong(), left).toInt())
            if (n > 0) left -= n
            return n
        }
    }

    private fun block(patch: File, offset: Long, length: Long): DataInputStream {
        val fin = FileInputStream(patch)
        var skipped = 0L
        while (skipped < offset) skipped += fin.skip(offset - skipped)
        return DataInputStream(BufferedInputStream(InflaterInputStream(Limited(fin, length), Inflater(), 1 shl 16), 1 shl 16))
    }

    fun apply(old: File, patch: File, out: File) {
        val header = ByteArray(48)
        RandomAccessFile(patch, "r").use { it.readFully(header) }
        require(header.copyOfRange(0, 8).contentEquals(MAGIC)) { "not an MFDELTA1 patch" }
        val newSize = le64(header, 8)
        val nCtrl = le64(header, 16)
        val lc = le64(header, 24)
        val ld = le64(header, 32)
        val le = le64(header, 40)
        require(nCtrl in 0..50_000_000 && newSize in 0..2_000_000_000L) { "corrupt patch header" }
        val ctrl = ByteArray((nCtrl * 24).toInt())
        block(patch, 48, lc).use { it.readFully(ctrl) }
        RandomAccessFile(old, "r").use { raf ->
            val oldMap = raf.channel.map(FileChannel.MapMode.READ_ONLY, 0, raf.length())
            val oldSize = raf.length()
            block(patch, 48 + lc, ld).use { diff ->
                block(patch, 48 + lc + ld, le).use { extra ->
                    BufferedOutputStream(FileOutputStream(out), 1 shl 20).use { w ->
                        val buf = ByteArray(1 shl 16)
                        var oldPos = 0L
                        var newPos = 0L
                        for (i in 0 until nCtrl.toInt()) {
                            val x = offtin(ctrl, i * 24)
                            val y = offtin(ctrl, i * 24 + 8)
                            val z = offtin(ctrl, i * 24 + 16)
                            require(x >= 0 && y >= 0 && newPos + x + y <= newSize) { "corrupt control block" }
                            var left = x
                            while (left > 0) {
                                val n = minOf(left, buf.size.toLong()).toInt()
                                diff.readFully(buf, 0, n)
                                for (k in 0 until n) {
                                    val p = oldPos + k
                                    if (p in 0 until oldSize) buf[k] = (buf[k] + oldMap.get(p.toInt())).toByte()
                                }
                                w.write(buf, 0, n)
                                oldPos += n
                                left -= n
                            }
                            newPos += x
                            left = y
                            while (left > 0) {
                                val n = minOf(left, buf.size.toLong()).toInt()
                                extra.readFully(buf, 0, n)
                                w.write(buf, 0, n)
                                left -= n
                            }
                            newPos += y
                            oldPos += z
                        }
                        require(newPos == newSize) { "patch produced $newPos of $newSize bytes" }
                    }
                }
            }
        }
    }
}

/** Gives the package installer read access to the rebuilt APK in cache/ota. */
class OtaFileProvider : androidx.core.content.FileProvider()
