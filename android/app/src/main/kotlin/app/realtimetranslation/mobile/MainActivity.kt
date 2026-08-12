package app.realtimetranslation.mobile

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlin.math.max

class MainActivity : FlutterActivity() {
    private var player: PcmStreamPlayer? = null
    private var audioEventSink: EventChannel.EventSink? = null
    private var permissionEventSink: EventChannel.EventSink? = null
    private val permissionHandler = Handler(Looper.getMainLooper())
    private var lastPermissionState: Boolean? = null
    private val permissionPoll = object : Runnable {
        override fun run() {
            if (permissionEventSink == null) return
            val granted = isMicrophonePermissionGranted()
            if (granted != lastPermissionState) {
                lastPermissionState = granted
                permissionEventSink?.success(granted)
            }
            permissionHandler.postDelayed(this, PERMISSION_POLL_MILLISECONDS)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val pcmPlayer = PcmStreamPlayer(this) {
            runOnUiThread { audioEventSink?.success("interrupted") }
        }
        player = pcmPlayer
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.realtimetranslation/audio_events",
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                audioEventSink = events
            }

            override fun onCancel(arguments: Any?) {
                audioEventSink = null
            }
        })
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.realtimetranslation/permission_events",
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                permissionEventSink = events
                lastPermissionState = null
                permissionHandler.removeCallbacks(permissionPoll)
                permissionPoll.run()
            }

            override fun onCancel(arguments: Any?) {
                permissionEventSink = null
                permissionHandler.removeCallbacks(permissionPoll)
            }
        })
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.realtimetranslation/permissions",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isGranted" -> result.success(isMicrophonePermissionGranted())
                "openAppSettings" -> {
                    val intent = Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:$packageName"),
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(intent)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.realtimetranslation/audio",
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "configure" -> {
                        val arguments = call.arguments as? Map<*, *>
                        val sampleRate = arguments?.get("sampleRate") as? Int ?: 24_000
                        pcmPlayer.configure(sampleRate)
                        result.success(null)
                    }
                    "enqueue" -> {
                        val bytes = call.arguments as? ByteArray
                        if (bytes == null) {
                            result.error("invalid_audio", "PCM payload is missing", null)
                        } else {
                            pcmPlayer.enqueue(bytes)
                            result.success(null)
                        }
                    }
                    "flush" -> {
                        pcmPlayer.flush()
                        result.success(null)
                    }
                    "metrics" -> result.success(pcmPlayer.metrics())
                    "dispose" -> {
                        pcmPlayer.dispose()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Throwable) {
                result.error("audio_failure", "Android audio output failed", null)
            }
        }
    }

    override fun onDestroy() {
        audioEventSink = null
        permissionEventSink = null
        permissionHandler.removeCallbacks(permissionPoll)
        player?.dispose()
        player = null
        super.onDestroy()
    }

    private fun isMicrophonePermissionGranted(): Boolean =
        checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private companion object {
        const val PERMISSION_POLL_MILLISECONDS = 750L
    }
}

private class PcmStreamPlayer(
    context: Context,
    private val onInterruption: () -> Unit,
) {
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val queue = ArrayBlockingQueue<ByteArray>(64)
    private val queueLock = Any()
    private val lifecycleLock = Any()
    private val writeLock = Any()
    private var audioTrack: AudioTrack? = null
    private var worker: Thread? = null
    private var running = false
    private var focusRequest: AudioFocusRequest? = null
    private var legacyFocusListener: AudioManager.OnAudioFocusChangeListener? = null
    @Volatile
    private var audioFocusGranted = false
    @Volatile
    private var lastOutputRoute = "unknown"
    @Volatile
    private var interruptionReported = false
    private var maxQueuedBytes = 72_000
    private var queuedBytes = 0
    private var droppedChunks = 0L

    fun configure(sampleRate: Int) = synchronized(lifecycleLock) {
        disposeLocked()
        val channelMask = AudioFormat.CHANNEL_OUT_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minimum = AudioTrack.getMinBufferSize(sampleRate, channelMask, encoding)
        val bufferBytes = max(minimum, sampleRate / 2)
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        val format = AudioFormat.Builder()
            .setSampleRate(sampleRate)
            .setEncoding(encoding)
            .setChannelMask(channelMask)
            .build()
        val builder = AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(format)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(bufferBytes)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
        }
        val track = builder.build()
        check(track.state == AudioTrack.STATE_INITIALIZED) {
            "AudioTrack failed to initialize"
        }
        try {
            audioTrack = track
            maxQueuedBytes = sampleRate * 2 * MAX_QUEUE_MILLISECONDS / 1_000
            droppedChunks = 0
            lastOutputRoute = "unknown"
            interruptionReported = false
            clearQueue()
            check(requestAudioFocus(attributes)) { "Audio focus was not granted" }
            routeToSpeaker()
            running = true
            track.play()
            worker = thread(name = "translated-pcm-playback", isDaemon = true) {
                while (running) {
                    val bytes = queue.poll(250, TimeUnit.MILLISECONDS) ?: continue
                    if (bytes.isEmpty()) continue
                    synchronized(queueLock) {
                        queuedBytes = (queuedBytes - bytes.size).coerceAtLeast(0)
                    }
                    synchronized(writeLock) {
                        if (running && track.playState == AudioTrack.PLAYSTATE_PLAYING) {
                            var offset = 0
                            while (running && offset < bytes.size) {
                                val written = track.write(
                                    bytes,
                                    offset,
                                    bytes.size - offset,
                                    AudioTrack.WRITE_BLOCKING,
                                )
                                if (written <= 0) {
                                    if (written < 0) running = false
                                    break
                                }
                                offset += written
                            }
                        }
                    }
                }
            }
        } catch (error: Throwable) {
            disposeLocked()
            throw error
        }
    }

    fun enqueue(bytes: ByteArray) {
        if (!running || bytes.isEmpty()) return
        updateLastOutputRoute()
        val copy = bytes.copyOf()
        synchronized(queueLock) {
            if (copy.size > maxQueuedBytes) {
                droppedChunks += 1
                return
            }
            while (queuedBytes + copy.size > maxQueuedBytes || queue.remainingCapacity() == 0) {
                val dropped = queue.poll() ?: break
                queuedBytes = (queuedBytes - dropped.size).coerceAtLeast(0)
                droppedChunks += 1
            }
            if (queue.offer(copy)) {
                queuedBytes += copy.size
            } else {
                droppedChunks += 1
            }
        }
    }

    fun flush() {
        clearQueue()
        synchronized(writeLock) {
            val track = audioTrack ?: return
            if (track.state == AudioTrack.STATE_INITIALIZED) {
                track.pause()
                track.flush()
                if (running) track.play()
            }
        }
    }

    fun metrics(): Map<String, Any> {
        updateLastOutputRoute()
        return synchronized(queueLock) {
            mapOf(
                "queuedBytes" to queuedBytes,
                "maxQueuedBytes" to maxQueuedBytes,
                "droppedChunks" to droppedChunks,
                "outputRoute" to lastOutputRoute,
                "audioFocusGranted" to audioFocusGranted,
            )
        }
    }

    fun dispose() = synchronized(lifecycleLock) {
        disposeLocked()
    }

    private fun disposeLocked() {
        running = false
        clearQueue()
        queue.offer(ByteArray(0))
        worker?.join(500)
        worker = null
        synchronized(writeLock) {
            audioTrack?.let { track ->
                try {
                    if (track.playState == AudioTrack.PLAYSTATE_PLAYING) track.stop()
                } catch (_: IllegalStateException) {
                    // The platform may already have released the route.
                }
                track.flush()
                track.release()
            }
            audioTrack = null
        }
        focusRequest?.let { request ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioManager.abandonAudioFocusRequest(request)
            }
        }
        focusRequest = null
        legacyFocusListener?.let { listener ->
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(listener)
        }
        legacyFocusListener = null
        audioFocusGranted = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audioManager.clearCommunicationDevice()
        } else {
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = false
        }
        audioManager.mode = AudioManager.MODE_NORMAL
    }

    private fun requestAudioFocus(attributes: AudioAttributes): Boolean {
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            if ((change == AudioManager.AUDIOFOCUS_LOSS ||
                    change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) &&
                running && !interruptionReported
            ) {
                interruptionReported = true
                audioFocusGranted = false
                flush()
                onInterruption()
            } else if (change == AudioManager.AUDIOFOCUS_GAIN) {
                audioFocusGranted = true
            }
        }
        val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attributes)
                .setAcceptsDelayedFocusGain(false)
                .setOnAudioFocusChangeListener(listener)
                .build()
            focusRequest = request
            audioManager.requestAudioFocus(request)
        } else {
            legacyFocusListener = listener
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                listener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
            )
        }
        audioFocusGranted = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        return audioFocusGranted
    }

    private fun routeToSpeaker() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val speaker = audioManager.availableCommunicationDevices.firstOrNull {
                it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
            }
            if (speaker != null) audioManager.setCommunicationDevice(speaker)
        } else {
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = true
        }
    }

    private fun routeName(type: Int?): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_LINE_ANALOG -> "wired"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BLE_SPEAKER -> "bluetooth"
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_ACCESSORY -> "usb"
        AudioDeviceInfo.TYPE_HEARING_AID -> "hearingAid"
        AudioDeviceInfo.TYPE_HDMI,
        AudioDeviceInfo.TYPE_HDMI_ARC,
        AudioDeviceInfo.TYPE_HDMI_EARC -> "hdmi"
        else -> "unknown"
    }

    private fun updateLastOutputRoute() {
        val currentRoute = routeName(audioTrack?.routedDevice?.type)
        if (currentRoute != "unknown") lastOutputRoute = currentRoute
    }

    private fun clearQueue() = synchronized(queueLock) {
        queue.clear()
        queuedBytes = 0
    }

    companion object {
        private const val MAX_QUEUE_MILLISECONDS = 1_500
    }
}
