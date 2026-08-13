package app.realtimetranslation.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackLifecycleTest {
    @Test
    fun `best effort cleanup runs every action after failures`() {
        val completed = mutableListOf<String>()

        BestEffortCleanup.run(
            { completed += "track-stop" },
            { throw IllegalStateException("platform stop failed") },
            { completed += "track-release" },
            { throw AssertionError("focus service failed") },
            { completed += "route-clear" },
            { completed += "mode-reset" },
        )

        assertEquals(
            listOf("track-stop", "track-release", "route-clear", "mode-reset"),
            completed,
        )
    }

    @Test
    fun `write pump retries a full non blocking buffer and preserves offsets`() {
        val writes = mutableListOf<Pair<Int, Int>>()
        val results = ArrayDeque(listOf(0, 3, 7))
        var waits = 0

        val outcome = PlaybackWritePump.write(
            byteCount = 10,
            isActive = { true },
            writeNonBlocking = { offset, byteCount ->
                writes += offset to byteCount
                results.removeFirst()
            },
            awaitWritable = { waits += 1 },
        )

        assertSame(PlaybackWriteOutcome.Completed, outcome)
        assertEquals(listOf(0 to 10, 0 to 10, 3 to 7), writes)
        assertEquals(1, waits)
        assertTrue(results.isEmpty())
    }

    @Test
    fun `negative platform result becomes a typed write failure`() {
        val outcome = PlaybackWritePump.write(
            byteCount = 64,
            isActive = { true },
            writeNonBlocking = { _, _ -> -6 },
            awaitWritable = { error("must not wait after an error") },
        )

        assertEquals(
            PlaybackWriteOutcome.Failed(
                PlaybackWriteFailure(reason = "writeError", platformCode = -6),
            ),
            outcome,
        )
        assertEquals(
            mapOf(
                "type" to "playbackFailed",
                "reason" to "writeError",
                "platformCode" to -6,
            ),
            (outcome as PlaybackWriteOutcome.Failed).failure.toEventPayload(),
        )
    }

    @Test
    fun `failure event carries the configured client generation`() {
        assertEquals(
            mapOf(
                "type" to "playbackFailed",
                "reason" to "writeError",
                "platformCode" to -6,
                "clientGeneration" to 42L,
            ),
            PlaybackWriteFailure(
                reason = "writeError",
                platformCode = -6,
                clientGeneration = 42L,
            ).toEventPayload(),
        )
    }

    @Test
    fun `chunk polled before flush cannot cross the generation boundary`() {
        val run = PlaybackRunState(clientGeneration = 7L)
        val staleChunk = requireNotNull(run.chunk(ByteArray(64)))

        assertTrue(run.invalidatePending())

        var writeCalled = false
        val outcome = PlaybackWritePump.write(
            byteCount = staleChunk.bytes.size,
            isActive = { run.accepts(staleChunk) },
            writeNonBlocking = { _, _ ->
                writeCalled = true
                staleChunk.bytes.size
            },
            awaitWritable = { error("must not wait for a stale chunk") },
        )

        assertSame(PlaybackWriteOutcome.Cancelled, outcome)
        assertFalse(writeCalled)
        val freshChunk = requireNotNull(run.chunk(ByteArray(64)))
        assertTrue(run.accepts(freshChunk))
    }

    @Test
    fun `focus loss stops the run so flush cannot resume or enqueue`() {
        val run = PlaybackRunState(clientGeneration = 9L)
        val queuedBeforeLoss = requireNotNull(run.chunk(ByteArray(64)))

        assertTrue(run.stop())
        assertFalse(run.invalidatePending())
        assertFalse(run.active)
        assertFalse(run.accepts(queuedBeforeLoss))
        assertNull(run.chunk(ByteArray(64)))
        assertFalse(run.stop())
    }

    @Test
    fun `write exception becomes a typed failure without leaking details`() {
        val outcome = PlaybackWritePump.write(
            byteCount = 64,
            isActive = { true },
            writeNonBlocking = { _, _ -> throw IllegalStateException("device serial") },
            awaitWritable = { error("must not wait after an error") },
        )

        val failure = (outcome as PlaybackWriteOutcome.Failed).failure
        assertEquals("writeException", failure.reason)
        assertNull(failure.platformCode)
        assertEquals(
            mapOf(
                "type" to "playbackFailed",
                "reason" to "writeException",
            ),
            failure.toEventPayload(),
        )
    }

    @Test
    fun `dispose race cancels an exceptional write without a failure`() {
        var active = true
        val outcome = PlaybackWritePump.write(
            byteCount = 64,
            isActive = { active },
            writeNonBlocking = { _, _ ->
                active = false
                throw IllegalStateException("released concurrently")
            },
            awaitWritable = { error("must not wait after cancellation") },
        )

        assertSame(PlaybackWriteOutcome.Cancelled, outcome)
    }

    @Test
    fun `inactive run cancels before touching the old track`() {
        var writeCalled = false

        val outcome = PlaybackWritePump.write(
            byteCount = 64,
            isActive = { false },
            writeNonBlocking = { _, _ ->
                writeCalled = true
                64
            },
            awaitWritable = { error("must not wait after cancellation") },
        )

        assertSame(PlaybackWriteOutcome.Cancelled, outcome)
        assertFalse(writeCalled)
    }

    @Test
    fun `interrupted retry cancels promptly and preserves interrupt status`() {
        try {
            val outcome = PlaybackWritePump.write(
                byteCount = 64,
                isActive = { true },
                writeNonBlocking = { _, _ -> 0 },
                awaitWritable = { throw InterruptedException("dispose") },
            )

            assertSame(PlaybackWriteOutcome.Cancelled, outcome)
            assertTrue(Thread.currentThread().isInterrupted)
        } finally {
            Thread.interrupted()
        }
    }

    @Test
    fun `impossible write count fails instead of corrupting the next offset`() {
        val outcome = PlaybackWritePump.write(
            byteCount = 64,
            isActive = { true },
            writeNonBlocking = { _, _ -> 65 },
            awaitWritable = { error("must not wait after an invalid result") },
        )

        assertEquals(
            PlaybackWriteOutcome.Failed(
                PlaybackWriteFailure(reason = "invalidWriteCount"),
            ),
            outcome,
        )
    }
}
