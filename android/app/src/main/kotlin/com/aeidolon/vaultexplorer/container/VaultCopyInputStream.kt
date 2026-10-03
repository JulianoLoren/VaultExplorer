package com.aeidolon.vaultexplorer.container

import java.io.IOException
import java.io.InputStream

/**
 * Reads one vault file as a plain [InputStream], a chunk at a time, entirely
 * in memory. It is the source half of [ContainerFileSystem]'s copy between a
 * folder vault and any other volume: the destination's `importStream` pulls
 * from this, so the decrypted bytes only ever exist in heap buffers -- never
 * in a temp file on disk.
 *
 * Unlike [ContainerInputStream] (which backs image decoding and treats a
 * failed chunk read as end-of-file), a failed or empty read *before* [total]
 * bytes have been delivered throws. A copy must never quietly end up shorter
 * than its source: the destination would be told the stream ended cleanly and
 * would commit a truncated file as if it were complete.
 *
 * @param readChunk returns up to `length` bytes starting at `offset`, or null
 *   on failure. Production passes [ContainerFileSystem.readFileChunk].
 * @param isCancelled polled before each chunk fetch; true aborts the copy.
 * @param onProgress receives the byte count of every read handed to the caller.
 */
internal class VaultCopyInputStream(
    private val total: Long,
    private val chunkSize: Int = DEFAULT_CHUNK_BYTES,
    private val readChunk: (offset: Long, length: Int) -> ByteArray?,
    private val isCancelled: () -> Boolean = { false },
    private val onProgress: (Long) -> Unit = {},
) : InputStream() {

    /** Bytes delivered to the caller so far; equals [total] after a full read. */
    var position: Long = 0L
        private set

    private var chunk: ByteArray? = null
    private var chunkPos = 0

    override fun read(): Int {
        val one = ByteArray(1)
        return if (read(one, 0, 1) <= 0) -1 else one[0].toInt() and 0xFF
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        if (position >= total) return -1

        val current = currentChunk()
        // Clamped to what the file still holds, so a backend that hands back
        // more than it was asked for can't push the copy past the source's size.
        val n = minOf(len.toLong(), (current.size - chunkPos).toLong(), total - position).toInt()
        System.arraycopy(current, chunkPos, b, off, n)
        chunkPos += n
        position += n
        onProgress(n.toLong())
        return n
    }

    /** The chunk holding the next unread byte, fetching (and wiping the last) if needed. */
    private fun currentChunk(): ByteArray {
        chunk?.let {
            if (chunkPos < it.size) return it
            it.fill(0)
            chunk = null
        }
        if (isCancelled()) throw IOException("copy cancelled at offset $position of $total")
        val want = minOf(chunkSize.toLong(), total - position).toInt()
        val fetched = readChunk(position, want)
        if (fetched == null || fetched.isEmpty()) {
            throw IOException("short read at offset $position of $total")
        }
        chunk = fetched
        chunkPos = 0
        return fetched
    }

    override fun available(): Int = chunk?.let { it.size - chunkPos } ?: 0

    override fun close() {
        chunk?.fill(0)
        chunk = null
    }

    companion object {
        const val DEFAULT_CHUNK_BYTES = 2 * 1024 * 1024
    }
}
