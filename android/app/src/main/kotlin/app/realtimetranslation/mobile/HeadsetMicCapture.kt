package app.realtimetranslation.mobile

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * Captures the microphone of a connected wired or Bluetooth headset,
 * independently of the built-in microphone, for headset-split mode.
 *
 * Fails closed: [isAvailable] reports false unless a headset microphone device
 * exists, and [start] throws when the recorder cannot bind to one.
 */
internal class HeadsetMicCapture(
    private val context: Context,
    private val audioManager: AudioManager,
) {
    private val sampleRate = 16_000
    private val channelConfig = AudioFormat.CHANNEL_IN_MONO
    private val encoding = AudioFormat.ENCODING_PCM_16BIT
    private val chunkBytes = sampleRate * 2 / 10

    @Volatile
    private var eventSink: EventChannel.EventSink? = null
    private var recorder: AudioRecord? = null
    private var worker: Thread? = null
    private val active = AtomicBoolean(false)

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    fun isAvailable(): Boolean {
        if (
            context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
                PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        return findHeadsetMicDevice() != null
    }

    private fun findHeadsetMicDevice(): AudioDeviceInfo? {
        val inputs = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
        return inputs.firstOrNull { device ->
            when (device.type) {
                AudioDeviceInfo.TYPE_WIRED_HEADSET,
                AudioDeviceInfo.TYPE_USB_HEADSET,
                AudioDeviceInfo.TYPE_USB_DEVICE,
                AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                AudioDeviceInfo.TYPE_BLE_HEADSET,
                AudioDeviceInfo.TYPE_HEARING_AID -> true
                else -> false
            }
        }
    }

    @SuppressLint("MissingPermission")
    fun start() {
        stop()
        val device = findHeadsetMicDevice()
            ?: throw IllegalStateException("No headset microphone is available")
        val minBuffer = AudioRecord.getMinBufferSize(sampleRate, channelConfig, encoding)
        val bufferBytes = maxOf(minBuffer, chunkBytes * 2)
        val record = try {
            AudioRecord.Builder()
                .setAudioSource(android.media.MediaRecorder.AudioSource.VOICE_COMMUNICATION)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(sampleRate)
                        .setEncoding(encoding)
                        .setChannelMask(channelConfig)
                        .build(),
                )
                .setBufferSizeInBytes(bufferBytes)
                .build()
        } catch (_: Throwable) {
            throw IllegalStateException("Headset microphone recorder failed to initialize")
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            throw IllegalStateException("Headset microphone recorder is not initialized")
        }
        if (!record.setPreferredDevice(device)) {
            record.release()
            throw IllegalStateException("Headset microphone device cannot be selected")
        }
        recorder = record
        record.startRecording()
        active.set(true)
        worker = thread(name = "headset-mic-capture", isDaemon = true) {
            captureLoop(record)
        }
    }

    private fun captureLoop(record: AudioRecord) {
        val buffer = ShortArray(chunkBytes / 2)
        while (active.get()) {
            val read = try {
                record.read(buffer, 0, buffer.size)
            } catch (_: Throwable) {
                -1
            }
            if (read <= 0) {
                if (read < 0) {
                    eventSink?.error(
                        "headset_read_failure",
                        "Headset microphone read failed: $read",
                        null,
                    )
                    active.set(false)
                    break
                }
                continue
            }
            val bytes = ByteArray(read * 2)
            for (i in 0 until read) {
                val sample = buffer[i].toInt()
                bytes[i * 2] = (sample and 0xff).toByte()
                bytes[i * 2 + 1] = ((sample shr 8) and 0xff).toByte()
            }
            eventSink?.success(bytes)
        }
    }

    fun stop() {
        active.set(false)
        val currentRecorder = recorder
        recorder = null
        val currentWorker = worker
        worker = null
        BestEffortCleanup.run(
            { currentWorker?.interrupt() },
            {
                if (currentWorker != null && currentWorker !== Thread.currentThread()) {
                    try {
                        currentWorker.join(500)
                    } catch (error: InterruptedException) {
                        Thread.currentThread().interrupt()
                        throw error
                    }
                }
            },
            {
                currentRecorder?.let { record ->
                    if (record.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                        record.stop()
                    }
                }
            },
            { currentRecorder?.release() },
        )
    }
}
