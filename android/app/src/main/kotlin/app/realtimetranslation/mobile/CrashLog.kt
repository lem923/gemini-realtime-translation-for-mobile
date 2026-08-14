package app.realtimetranslation.mobile

import android.content.Context
import java.io.File

/**
 * Bounded crash log for device-specific diagnostics.
 *
 * Native uncaught exceptions are appended to an app-private file (never
 * uploaded; exported only when the user opens the diagnostics dialog and
 * copies the report). Entries contain exception messages only.
 */
internal object CrashLog {
    private const val MAX_BYTES = 32 * 1024
    private const val READ_TAIL_BYTES = 4096
    private const val FILE_NAME = "crash_log.txt"

    fun install(context: Context) {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val file = File(context.filesDir, FILE_NAME)
                val entry =
                    "${System.currentTimeMillis()} ${thread.name}: ${throwable}\n"
                file.appendText(entry)
                if (file.length() > MAX_BYTES) {
                    val content = file.readText()
                    file.writeText(content.takeLast(MAX_BYTES))
                }
            } catch (_: Throwable) {
                // Crash logging must never mask the original failure.
            }
            previous?.uncaughtException(thread, throwable)
        }
    }

    fun read(context: Context): String {
        return try {
            val file = File(context.filesDir, FILE_NAME)
            if (!file.exists()) {
                ""
            } else {
                file.readText().takeLast(READ_TAIL_BYTES)
            }
        } catch (_: Throwable) {
            ""
        }
    }
}
