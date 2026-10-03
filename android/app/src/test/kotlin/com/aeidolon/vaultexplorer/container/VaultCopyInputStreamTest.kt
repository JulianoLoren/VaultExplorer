package com.aeidolon.vaultexplorer.container

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.IOException

class VaultCopyInputStreamTest {

    private fun source(size: Int) = ByteArray(size) { (it * 31 + 7).toByte() }

    /** A readChunk that serves [data], recording every (offset, length) asked for. */
    private class FakeSource(val data: ByteArray) {
        val requests = mutableListOf<Pair<Long, Int>>()
        val served = mutableListOf<ByteArray>()

        fun read(offset: Long, length: Int): ByteArray? {
            requests += offset to length
            val end = minOf(data.size.toLong(), offset + length).toInt()
            val chunk = data.copyOfRange(offset.toInt(), end)
            served += chunk
            return chunk
        }
    }

    @Test
    fun deliversEveryByteAcrossChunkBoundaries() {
        val data = source(25)
        val fake = FakeSource(data)
        val progress = mutableListOf<Long>()
        val stream = VaultCopyInputStream(
            total = data.size.toLong(),
            chunkSize = 8,
            readChunk = fake::read,
            onProgress = { progress += it },
        )

        val out = stream.readBytes()

        assertArrayEquals(data, out)
        assertEquals(data.size.toLong(), stream.position)
        assertEquals("progress must add up to the file size", data.size.toLong(), progress.sum())
    }

    @Test
    fun neverAsksForMoreThanAChunkOrPastTheEnd() {
        val fake = FakeSource(source(10))
        val stream = VaultCopyInputStream(total = 10, chunkSize = 4, readChunk = fake::read)

        stream.readBytes()

        assertEquals(listOf(0L to 4, 4L to 4, 8L to 2), fake.requests)
    }

    @Test
    fun reportsEndOfStreamAtTotalWithoutAnotherFetch() {
        val fake = FakeSource(source(6))
        val stream = VaultCopyInputStream(total = 6, chunkSize = 6, readChunk = fake::read)
        stream.readBytes()
        val fetches = fake.requests.size

        assertEquals(-1, stream.read(ByteArray(4), 0, 4))
        assertEquals(-1, stream.read())
        assertEquals(fetches, fake.requests.size)
    }

    @Test
    fun singleByteReadsReturnUnsignedValues() {
        val data = byteArrayOf(0x00, 0x7F, 0x80.toByte(), 0xFF.toByte())
        val stream = VaultCopyInputStream(total = 4, chunkSize = 2, readChunk = FakeSource(data)::read)

        assertEquals(listOf(0x00, 0x7F, 0x80, 0xFF), List(4) { stream.read() })
        assertEquals(-1, stream.read())
    }

    @Test
    fun aFailedChunkReadThrowsInsteadOfLookingLikeEndOfFile() {
        val data = source(12)
        var calls = 0
        val stream = VaultCopyInputStream(
            total = 12,
            chunkSize = 4,
            readChunk = { offset, length ->
                calls++
                if (calls == 2) null else data.copyOfRange(offset.toInt(), offset.toInt() + length)
            },
        )

        try {
            stream.readBytes()
            fail("a copy must not silently end short")
        } catch (e: IOException) {
            assertTrue(e.message!!.contains("short read"))
        }
        assertEquals("only the first chunk was delivered", 4L, stream.position)
    }

    @Test
    fun anEmptyChunkBeforeTheEndIsAlsoAnError() {
        val stream = VaultCopyInputStream(total = 8, chunkSize = 4, readChunk = { _, _ -> ByteArray(0) })

        try {
            stream.read(ByteArray(4), 0, 4)
            fail("expected IOException")
        } catch (_: IOException) {
        }
    }

    @Test
    fun cancellationStopsBeforeTheNextChunkIsFetched() {
        val fake = FakeSource(source(16))
        var cancelled = false
        val stream = VaultCopyInputStream(
            total = 16,
            chunkSize = 4,
            readChunk = fake::read,
            isCancelled = { cancelled },
        )
        val buf = ByteArray(4)
        assertEquals(4, stream.read(buf, 0, 4))

        cancelled = true

        try {
            stream.read(buf, 0, 4)
            fail("expected IOException")
        } catch (e: IOException) {
            assertTrue(e.message!!.contains("cancelled"))
        }
        assertEquals("no chunk was fetched after the cancel", 1, fake.requests.size)
    }

    @Test
    fun closingWipesTheBufferedPlaintext() {
        val fake = FakeSource(source(8))
        val stream = VaultCopyInputStream(total = 8, chunkSize = 8, readChunk = fake::read)
        stream.read(ByteArray(2), 0, 2) // leaves most of the chunk unread
        val held = fake.served.single()
        assertFalse("sanity: the chunk holds data", held.all { it == 0.toByte() })

        stream.close()

        assertTrue("the chunk buffer must be zeroed on close", held.all { it == 0.toByte() })
    }

    @Test
    fun advancingToTheNextChunkWipesThePreviousOne() {
        val fake = FakeSource(source(8))
        val stream = VaultCopyInputStream(total = 8, chunkSize = 4, readChunk = fake::read)

        stream.read(ByteArray(4), 0, 4)
        val first = fake.served.first()
        stream.read(ByteArray(4), 0, 4) // forces the second fetch

        assertTrue(first.all { it == 0.toByte() })
    }
}
