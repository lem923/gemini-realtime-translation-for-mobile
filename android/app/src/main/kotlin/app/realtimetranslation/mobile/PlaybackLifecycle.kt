package app.realtimetranslation.mobile

internal object BestEffortCleanup {
    fun run(vararg actions: () -> Unit) {
        for (action in actions) {
            try {
                action()
            } catch (_: Throwable) {
                // Cleanup ownership has already been cleared by the caller. Keep
                // releasing the remaining, independently owned resources.
            }
        }
    }
}

internal data class PlaybackWriteFailure(
    val reason: String,
    val platformCode: Int? = null,
    val clientGeneration: Long? = null,
)

internal fun PlaybackWriteFailure.toEventPayload(): Map<String, Any> {
    val event = mutableMapOf<String, Any>(
        "type" to "playbackFailed",
        "reason" to reason,
    )
    platformCode?.let { code -> event["platformCode"] = code }
    clientGeneration?.let { generation -> event["clientGeneration"] = generation }
    return event
}

internal data class PlaybackChunk(
    val bytes: ByteArray,
    val writeGeneration: Long,
)

/**
 * One configured native playback lifetime.
 *
 * Each queued block captures the write generation at enqueue time. A flush
 * advances that generation, so a block already removed from the queue cannot
 * cross the flush boundary and reach AudioTrack afterwards.
 */
internal class PlaybackRunState(val clientGeneration: Long) {
    @Volatile
    var active = true
        private set

    @Volatile
    private var writeGeneration = 0L

    fun chunk(bytes: ByteArray): PlaybackChunk? = synchronized(this) {
        if (!active) return@synchronized null
        PlaybackChunk(bytes = bytes, writeGeneration = writeGeneration)
    }

    fun accepts(chunk: PlaybackChunk): Boolean = synchronized(this) {
        active && chunk.writeGeneration == writeGeneration
    }

    /** Invalidates pending blocks and reports whether playback may resume. */
    fun invalidatePending(): Boolean = synchronized(this) {
        writeGeneration += 1L
        active
    }

    /** Terminal for this configured run; focus gain cannot reactivate it. */
    fun stop(): Boolean = synchronized(this) {
        if (!active) return@synchronized false
        active = false
        writeGeneration += 1L
        true
    }
}

internal sealed class PlaybackWriteOutcome {
    data object Completed : PlaybackWriteOutcome()

    data object Cancelled : PlaybackWriteOutcome()

    data class Failed(val failure: PlaybackWriteFailure) : PlaybackWriteOutcome()
}

internal object PlaybackWritePump {
    fun write(
        byteCount: Int,
        isActive: () -> Boolean,
        writeNonBlocking: (offset: Int, byteCount: Int) -> Int,
        awaitWritable: () -> Unit,
    ): PlaybackWriteOutcome {
        var offset = 0
        while (offset < byteCount) {
            if (!isActive()) return PlaybackWriteOutcome.Cancelled

            val remaining = byteCount - offset
            val written = try {
                writeNonBlocking(offset, remaining)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return PlaybackWriteOutcome.Cancelled
            } catch (_: Throwable) {
                return if (isActive()) {
                    PlaybackWriteOutcome.Failed(
                        PlaybackWriteFailure(reason = "writeException"),
                    )
                } else {
                    PlaybackWriteOutcome.Cancelled
                }
            }

            if (!isActive()) return PlaybackWriteOutcome.Cancelled
            when {
                written < 0 -> return PlaybackWriteOutcome.Failed(
                    PlaybackWriteFailure(
                        reason = "writeError",
                        platformCode = written,
                    ),
                )
                written == 0 -> {
                    try {
                        awaitWritable()
                    } catch (_: InterruptedException) {
                        Thread.currentThread().interrupt()
                        return PlaybackWriteOutcome.Cancelled
                    } catch (_: Throwable) {
                        return if (isActive()) {
                            PlaybackWriteOutcome.Failed(
                                PlaybackWriteFailure(reason = "writeRetryException"),
                            )
                        } else {
                            PlaybackWriteOutcome.Cancelled
                        }
                    }
                }
                written > remaining -> return PlaybackWriteOutcome.Failed(
                    PlaybackWriteFailure(reason = "invalidWriteCount"),
                )
                else -> offset += written
            }
        }
        return PlaybackWriteOutcome.Completed
    }
}
