package app.realtimetranslation.mobile

import android.content.Context
import android.media.AudioAttributes
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.io.File
import java.util.Locale
import java.util.UUID

/**
 * Synthesizes text to a WAV file with the system TTS engine so the result can
 * be played through the existing PCM playback gateway (keeping mute, queue,
 * and echo-guard behavior). Fails closed when no engine or voice is
 * available.
 */
internal class SystemTts(
    private val context: Context,
) {
    private var tts: TextToSpeech? = null
    private var ready = false
    private val pending = java.util.concurrent.ConcurrentLinkedQueue<PendingRequest>()

    private class PendingRequest(
        val text: String,
        val languageCode: String,
        val onResult: (String?) -> Unit,
    )

    fun init() {
        if (tts != null) {
            return
        }
        tts = TextToSpeech(context.applicationContext) { status ->
            if (status == TextToSpeech.SUCCESS) {
                ready = true
                val engine = tts
                engine?.setOnUtteranceProgressListener(
                    object : UtteranceProgressListener() {
                        override fun onStart(utteranceId: String?) {}

                        override fun onDone(utteranceId: String?) {
                            if (utteranceId == null) {
                                return
                            }
                            val file = File(utteranceId)
                            val request = removeRequest(utteranceId)
                            if (request != null) {
                                request.onResult(
                                    if (file.exists()) file.absolutePath else null,
                                )
                            }
                        }

                        @Deprecated("Deprecated in Java")
                        override fun onError(utteranceId: String?) {
                            if (utteranceId == null) {
                                return
                            }
                            val request = removeRequest(utteranceId)
                            request?.onResult(null)
                        }
                    },
                )
                drain()
            } else {
                ready = false
            }
        }
    }

    @Synchronized
    private fun removeRequest(utteranceId: String): PendingRequest? {
        var found: PendingRequest? = null
        val iterator = pending.iterator()
        while (iterator.hasNext()) {
            val candidate = iterator.next()
            if (candidate.text + candidate.languageCode == utteranceId) {
                found = candidate
                iterator.remove()
                break
            }
        }
        return found
    }

    @Synchronized
    private fun drain() {
        while (true) {
            val request = pending.poll() ?: break
            synthesizeNow(request)
        }
    }

    private fun synthesizeNow(request: PendingRequest) {
        val engine = tts ?: run {
            request.onResult(null)
            return
        }
        val locale = Locale.forLanguageTag(request.languageCode)
        val languageResult = engine.setLanguage(locale)
        if (languageResult != TextToSpeech.LANG_AVAILABLE &&
            languageResult != TextToSpeech.LANG_COUNTRY_AVAILABLE &&
            languageResult != TextToSpeech.LANG_COUNTRY_VAR_AVAILABLE
        ) {
            request.onResult(null)
            return
        }
        engine.setSpeechRate(1.0f)
        engine.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build(),
        )
        val outputFile = File(
            context.cacheDir,
            "tts_${System.currentTimeMillis()}_${UUID.randomUUID()}.wav",
        )
        val utteranceId = request.text + request.languageCode
        val result = engine.synthesizeToFile(
            request.text,
            android.os.Bundle().apply {
                putString(
                    TextToSpeech.Engine.KEY_PARAM_UTTERANCE_ID,
                    utteranceId,
                )
            },
            outputFile,
            utteranceId,
        )
        if (result != TextToSpeech.SUCCESS) {
            request.onResult(null)
        }
    }

    fun synthesize(
        text: String,
        languageCode: String,
        onResult: (String?) -> Unit,
    ) {
        if (!ready) {
            init()
            pending.add(PendingRequest(text, languageCode, onResult))
            return
        }
        val request = PendingRequest(text, languageCode, onResult)
        pending.add(request)
        drain()
    }

    fun shutdown() {
        ready = false
        tts?.shutdown()
        tts = null
    }
}
