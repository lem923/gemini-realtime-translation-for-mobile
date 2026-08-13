package app.realtimetranslation.mobile

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
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
    private var headsetMicCapture: HeadsetMicCapture? = null
    private var audioEventSink: EventChannel.EventSink? = null
    private var permissionEventSink: EventChannel.EventSink? = null
    private val permissionHandler = Handler(Looper.getMainLooper())
    private var lastPermissionState: String? = null
    private val permissionPoll = object : Runnable {
        override fun run() {
            if (permissionEventSink == null) return
            val status = microphonePermissionStatus()
            if (status != lastPermissionState) {
                lastPermissionState = status
                permissionEventSink?.success(status)
            }
            permissionHandler.postDelayed(this, PERMISSION_POLL_MILLISECONDS)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val pcmPlayer = PcmStreamPlayer(
            context = this,
            onInterruption = {
                runOnUiThread { audioEventSink?.success("interrupted") }
            },
            onPlaybackFailure = { failure ->
                runOnUiThread {
                    audioEventSink?.success(failure.toEventPayload())
                }
            },
            onRouteChanged = { route ->
                runOnUiThread {
                    audioEventSink?.success(
                        mapOf(
                            "type" to "routeChanged",
                            "outputRoute" to route,
                        ),
                    )
                }
            },
        )
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
                "status" -> result.success(microphonePermissionStatus())
                "recordRequestResult" -> {
                    val granted = call.argument<Boolean>("granted")
                    if (granted == null) {
                        result.error(
                            "invalid_permission_result",
                            "Permission result is missing",
                            null,
                        )
                    } else {
                        val preferences = getSharedPreferences(
                            PERMISSION_PREFERENCES,
                            Context.MODE_PRIVATE,
                        )
                        preferences.edit()
                            .putBoolean(MICROPHONE_REQUEST_ANSWERED, true)
                            .putBoolean(
                                MICROPHONE_EVER_GRANTED,
                                granted || preferences.getBoolean(
                                    MICROPHONE_EVER_GRANTED,
                                    false,
                                ),
                            )
                            .apply()
                        lastPermissionState = null
                        result.success(null)
                    }
                }
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
                        val clientGeneration =
                            (arguments?.get("clientGeneration") as? Number)?.toLong() ?: 0L
                        pcmPlayer.configure(sampleRate, clientGeneration)
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
                    "enqueueTrack" -> {
                        val arguments = call.arguments as? Map<*, *>
                        val bytes = arguments?.get("pcm") as? ByteArray
                        val trackName = arguments?.get("track") as? String
                        if (bytes == null || trackName == null) {
                            result.error("invalid_audio", "Track or PCM payload is missing", null)
                        } else {
                            pcmPlayer.enqueueTrack(trackName, bytes)
                            result.success(null)
                        }
                    }
                    "flush" -> {
                        pcmPlayer.flush()
                        result.success(null)
                    }
                    "flushTrack" -> {
                        val trackName = call.arguments as? String
                        if (trackName == null) {
                            result.error("invalid_audio", "Track name is missing", null)
                        } else {
                            pcmPlayer.flushTrack(trackName)
                            result.success(null)
                        }
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
        val headsetCapture = HeadsetMicCapture(
            context = this,
            audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager,
        )
        headsetMicCapture = headsetCapture
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.realtimetranslation/headset_capture",
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "state" -> result.success(
                        if (headsetCapture.isAvailable()) "available" else "unavailable",
                    )
                    "start" -> {
                        headsetCapture.start()
                        result.success(null)
                    }
                    "stop" -> {
                        headsetCapture.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Throwable) {
                result.error("headset_capture_failure", "Headset capture failed", null)
            }
        }
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.realtimetranslation/headset_capture_events",
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                headsetCapture.setEventSink(events)
            }

            override fun onCancel(arguments: Any?) {
                headsetCapture.setEventSink(null)
            }
        })
    }

    override fun onDestroy() {
        try {
            audioEventSink = null
            permissionEventSink = null
            val currentPlayer = player
            player = null
            val currentHeadset = headsetMicCapture
            headsetMicCapture = null
            BestEffortCleanup.run(
                { permissionHandler.removeCallbacks(permissionPoll) },
                { currentPlayer?.dispose() },
                { currentHeadset?.stop() },
            )
        } finally {
            super.onDestroy()
        }
    }

    private fun microphonePermissionStatus(): String {
        if (
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
        ) {
            val preferences = getSharedPreferences(
                PERMISSION_PREFERENCES,
                Context.MODE_PRIVATE,
            )
            if (!preferences.getBoolean(MICROPHONE_EVER_GRANTED, false)) {
                preferences.edit().putBoolean(MICROPHONE_EVER_GRANTED, true).apply()
            }
            return PERMISSION_GRANTED
        }
        val preferences = getSharedPreferences(
            PERMISSION_PREFERENCES,
            Context.MODE_PRIVATE,
        )
        val requestAnswered = preferences.getBoolean(
            MICROPHONE_REQUEST_ANSWERED,
            false,
        )
        val wasGranted = preferences.getBoolean(MICROPHONE_EVER_GRANTED, false)
        return if (requestAnswered || wasGranted) {
            PERMISSION_DENIED
        } else {
            PERMISSION_NOT_DETERMINED
        }
    }

    private companion object {
        const val PERMISSION_POLL_MILLISECONDS = 750L
        const val PERMISSION_PREFERENCES = "permission_state"
        const val MICROPHONE_REQUEST_ANSWERED = "microphone_request_answered"
        const val MICROPHONE_EVER_GRANTED = "microphone_ever_granted"
        const val PERMISSION_NOT_DETERMINED = "notDetermined"
        const val PERMISSION_GRANTED = "granted"
        const val PERMISSION_DENIED = "denied"
    }
}

private class PcmStreamPlayer(
    context: Context,
    private val onInterruption: () -> Unit,
    private val onPlaybackFailure: (PlaybackWriteFailure) -> Unit,
    private val onRouteChanged: (String) -> Unit,
) {
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val queue = ArrayBlockingQueue<PlaybackChunk>(64)
    private val queueLock = Any()
    private val lifecycleLock = Any()
    private val trackOperationLock = Any()
    @Volatile
    private var audioTrack: AudioTrack? = null
    private var worker: Thread? = null
    @Volatile
    private var playbackRun: PlaybackRunState? = null
    private var focusRequest: AudioFocusRequest? = null
    private var legacyFocusListener: AudioManager.OnAudioFocusChangeListener? = null
    private var audioDeviceCallbackRegistered = false
    private var communicationRouteOwned = false
    private var communicationModeOwned = false
    private val audioDeviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
            refreshCommunicationRoute()
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
            refreshCommunicationRoute()
        }
    }
    @Volatile
    private var audioFocusGranted = false
    @Volatile
    private var lastOutputRoute = "unknown"
    @Volatile
    private var interruptionReported = false
    private var maxQueuedBytes = 72_000
    private var queuedBytes = 0
    private var droppedChunks = 0L
    @Volatile
    private var headsetTrack: AudioTrack? = null
    private val headsetQueue = ArrayBlockingQueue<PlaybackChunk>(64)
    private var headsetMaxQueuedBytes = 72_000
    private var headsetQueuedBytes = 0
    private var headsetWorker: Thread? = null

    fun configure(sampleRate: Int, clientGeneration: Long) = synchronized(lifecycleLock) {
        disposeLocked()
        val channelMask = AudioFormat.CHANNEL_OUT_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minimum = AudioTrack.getMinBufferSize(sampleRate, channelMask, encoding)
        val bufferBytes = max(minimum, sampleRate / 2)
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
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
        try {
            check(track.state == AudioTrack.STATE_INITIALIZED) {
                "AudioTrack failed to initialize"
            }
        } catch (error: Throwable) {
            BestEffortCleanup.run({ track.release() })
            throw error
        }
        try {
            audioTrack = track
            maxQueuedBytes = sampleRate * 2 * MAX_QUEUE_MILLISECONDS / 1_000
            headsetMaxQueuedBytes = maxQueuedBytes
            droppedChunks = 0
            lastOutputRoute = "unknown"
            interruptionReported = false
            clearQueue()
            clearHeadsetQueue()
            val run = PlaybackRunState(clientGeneration)
            playbackRun = run
            check(requestAudioFocus(attributes, run)) { "Audio focus was not granted" }
            registerAudioDeviceCallback()
            selectPreferredCommunicationDevice()
            track.play()
            configureHeadsetLane(sampleRate, run)
            worker = thread(name = "translated-pcm-playback", isDaemon = true) {
                while (run.active) {
                    val chunk = try {
                        queue.poll(250, TimeUnit.MILLISECONDS)
                    } catch (_: InterruptedException) {
                        Thread.currentThread().interrupt()
                        break
                    } ?: continue
                    if (chunk.bytes.isEmpty()) continue
                    synchronized(queueLock) {
                        queuedBytes = (queuedBytes - chunk.bytes.size).coerceAtLeast(0)
                    }
                    val outcome = PlaybackWritePump.write(
                        byteCount = chunk.bytes.size,
                        isActive = {
                            playbackRun === run && run.accepts(chunk)
                        },
                        writeNonBlocking = { offset, byteCount ->
                            synchronized(trackOperationLock) {
                                if (
                                    playbackRun !== run ||
                                    !run.accepts(chunk)
                                ) {
                                    0
                                } else {
                                    track.write(
                                        chunk.bytes,
                                        offset,
                                        byteCount,
                                        AudioTrack.WRITE_NON_BLOCKING,
                                    )
                                }
                            }
                        },
                        awaitWritable = {
                            Thread.sleep(NON_BLOCKING_RETRY_MILLISECONDS)
                        },
                    )
                    when (outcome) {
                        PlaybackWriteOutcome.Completed -> {
                            updateLastOutputRoute()
                        }
                        PlaybackWriteOutcome.Cancelled -> {
                            if (!run.active || playbackRun !== run) break
                        }
                        is PlaybackWriteOutcome.Failed -> {
                            run.stop()
                            if (playbackRun === run) {
                                onPlaybackFailure(
                                    outcome.failure.copy(
                                        clientGeneration = run.clientGeneration,
                                    ),
                                )
                            }
                            break
                        }
                    }
                }
            }
        } catch (error: Throwable) {
            disposeLocked()
            throw error
        }
    }

    private fun configureHeadsetLane(sampleRate: Int, run: PlaybackRunState) {
        val headsetDevice = selectHeadsetOutputDevice()
        if (headsetDevice == null) {
            headsetTrack = null
            return
        }
        val minimum = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val track = try {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(sampleRate)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(maxOf(minimum, sampleRate / 2))
                .build()
        } catch (_: Throwable) {
            null
        }
        if (track == null || track.state != AudioTrack.STATE_INITIALIZED) {
            track?.release()
            headsetTrack = null
            return
        }
        if (!track.setPreferredDevice(headsetDevice)) {
            track.release()
            headsetTrack = null
            return
        }
        headsetTrack = track
        track.play()
        headsetWorker = thread(name = "translated-pcm-headset", isDaemon = true) {
            while (run.active && headsetTrack === track) {
                val chunk = try {
                    headsetQueue.poll(250, TimeUnit.MILLISECONDS)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    break
                } ?: continue
                if (chunk.bytes.isEmpty()) continue
                synchronized(queueLock) {
                    headsetQueuedBytes = (headsetQueuedBytes - chunk.bytes.size).coerceAtLeast(0)
                }
                val outcome = PlaybackWritePump.write(
                    byteCount = chunk.bytes.size,
                    isActive = {
                        playbackRun === run && run.accepts(chunk) && headsetTrack === track
                    },
                    writeNonBlocking = { offset, byteCount ->
                        synchronized(trackOperationLock) {
                            if (
                                playbackRun !== run ||
                                !run.accepts(chunk) ||
                                headsetTrack !== track
                            ) {
                                0
                            } else {
                                track.write(
                                    chunk.bytes,
                                    offset,
                                    byteCount,
                                    AudioTrack.WRITE_NON_BLOCKING,
                                )
                            }
                        }
                    },
                    awaitWritable = {
                        Thread.sleep(NON_BLOCKING_RETRY_MILLISECONDS)
                    },
                )
                when (outcome) {
                    PlaybackWriteOutcome.Completed -> Unit
                    PlaybackWriteOutcome.Cancelled -> {
                        if (!run.active || headsetTrack !== track) break
                    }
                    is PlaybackWriteOutcome.Failed -> {
                        run.stop()
                        if (playbackRun === run) {
                            onPlaybackFailure(
                                outcome.failure.copy(
                                    clientGeneration = run.clientGeneration,
                                ),
                            )
                        }
                        break
                    }
                }
            }
        }
    }

    private fun selectHeadsetOutputDevice(): AudioDeviceInfo? {
        val outputs = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        return outputs.firstOrNull { device ->
            when (device.type) {
                AudioDeviceInfo.TYPE_WIRED_HEADSET,
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                AudioDeviceInfo.TYPE_LINE_ANALOG,
                AudioDeviceInfo.TYPE_USB_HEADSET,
                AudioDeviceInfo.TYPE_USB_DEVICE,
                AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                AudioDeviceInfo.TYPE_BLE_HEADSET,
                AudioDeviceInfo.TYPE_HEARING_AID -> true
                else -> false
            }
        }
    }

    private fun clearHeadsetQueue() = synchronized(queueLock) {
        headsetQueue.clear()
        headsetQueuedBytes = 0
    }

    fun enqueue(bytes: ByteArray) = synchronized(lifecycleLock) enqueue@{
        if (bytes.isEmpty()) return@enqueue
        val run = playbackRun ?: return@enqueue
        val chunk = run.chunk(bytes.copyOf()) ?: return@enqueue
        updateLastOutputRoute()
        synchronized(queueLock) {
            if (chunk.bytes.size > maxQueuedBytes) {
                droppedChunks += 1
                return@enqueue
            }
            while (
                queuedBytes + chunk.bytes.size > maxQueuedBytes ||
                queue.remainingCapacity() == 0
            ) {
                val dropped = queue.poll() ?: break
                queuedBytes = (queuedBytes - dropped.bytes.size).coerceAtLeast(0)
                droppedChunks += 1
            }
            if (queue.offer(chunk)) {
                queuedBytes += chunk.bytes.size
            } else {
                droppedChunks += 1
            }
        }
    }

    /**
     * Headset-split output: the "headset" track plays through a wired or
     * Bluetooth headset while the default track keeps the phone speaker.
     * Fails closed when no headset output device is available.
     */
    fun enqueueTrack(trackName: String, bytes: ByteArray) =
        synchronized(lifecycleLock) enqueueTrack@{
            if (trackName == "phoneSpeaker") {
                return@enqueueTrack enqueue(bytes)
            }
            if (trackName != "headset") return@enqueueTrack
            if (bytes.isEmpty()) return@enqueueTrack
            val run = playbackRun ?: return@enqueueTrack
            val chunk = run.chunk(bytes.copyOf()) ?: return@enqueueTrack
            val track = headsetTrack
            if (track == null || track.state != AudioTrack.STATE_INITIALIZED) {
                droppedChunks += 1
                return@enqueueTrack
            }
            synchronized(queueLock) {
                if (chunk.bytes.size > headsetMaxQueuedBytes) {
                    droppedChunks += 1
                    return@enqueueTrack
                }
                while (
                    headsetQueuedBytes + chunk.bytes.size > headsetMaxQueuedBytes ||
                    headsetQueue.remainingCapacity() == 0
                ) {
                    val dropped = headsetQueue.poll() ?: break
                    headsetQueuedBytes = (headsetQueuedBytes - dropped.bytes.size).coerceAtLeast(0)
                    droppedChunks += 1
                }
                if (headsetQueue.offer(chunk)) {
                    headsetQueuedBytes += chunk.bytes.size
                } else {
                    droppedChunks += 1
                }
            }
        }

    fun flush() = synchronized(lifecycleLock) {
        flushLocked()
    }

    fun flushTrack(trackName: String) = synchronized(lifecycleLock) {
        if (trackName == "headset") {
            flushHeadsetLocked()
        } else {
            flushLocked()
        }
    }

    private fun flushHeadsetLocked() {
        val run = playbackRun
        run?.invalidatePending()
        synchronized(queueLock) {
            headsetQueue.clear()
            headsetQueuedBytes = 0
        }
        val track = headsetTrack ?: return
        synchronized(trackOperationLock) {
            if (track.state == AudioTrack.STATE_INITIALIZED) {
                track.pause()
                track.flush()
                if (playbackRun === run && run?.active == true) {
                    track.play()
                }
            }
        }
    }

    private fun flushLocked(resumePlayback: Boolean = true) {
        val run = playbackRun
        val runMayResume = run?.invalidatePending() == true
        clearQueue()
        clearHeadsetQueue()
        val track = audioTrack ?: return
        synchronized(trackOperationLock) {
            if (track.state == AudioTrack.STATE_INITIALIZED) {
                track.pause()
                track.flush()
                if (resumePlayback && playbackRun === run && runMayResume) {
                    track.play()
                }
            }
        }
        val headset = headsetTrack
        if (headset != null) {
            synchronized(trackOperationLock) {
                if (headset.state == AudioTrack.STATE_INITIALIZED) {
                    headset.pause()
                    headset.flush()
                    if (resumePlayback && playbackRun === run && runMayResume) {
                        headset.play()
                    }
                }
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
        val run = playbackRun
        playbackRun = null
        run?.stop()
        val workerToJoin = worker
        worker = null
        val headsetWorkerToJoin = headsetWorker
        headsetWorker = null
        val track = audioTrack
        audioTrack = null
        val headset = headsetTrack
        headsetTrack = null
        val request = focusRequest
        focusRequest = null
        val legacyListener = legacyFocusListener
        legacyFocusListener = null
        val unregisterDeviceCallback = audioDeviceCallbackRegistered
        audioDeviceCallbackRegistered = false
        val clearCommunicationRoute = communicationRouteOwned
        communicationRouteOwned = false
        val resetCommunicationMode = communicationModeOwned
        communicationModeOwned = false
        audioFocusGranted = false
        interruptionReported = false
        lastOutputRoute = "unknown"

        BestEffortCleanup.run(
            { clearQueue() },
            { clearHeadsetQueue() },
            { workerToJoin?.interrupt() },
            { headsetWorkerToJoin?.interrupt() },
            {
                if (workerToJoin != null && workerToJoin !== Thread.currentThread()) {
                    try {
                        workerToJoin.join(WORKER_JOIN_MILLISECONDS)
                    } catch (error: InterruptedException) {
                        Thread.currentThread().interrupt()
                        throw error
                    }
                }
            },
            {
                if (headsetWorkerToJoin != null &&
                    headsetWorkerToJoin !== Thread.currentThread()
                ) {
                    try {
                        headsetWorkerToJoin.join(WORKER_JOIN_MILLISECONDS)
                    } catch (error: InterruptedException) {
                        Thread.currentThread().interrupt()
                        throw error
                    }
                }
            },
            {
                if (track?.playState == AudioTrack.PLAYSTATE_PLAYING) track.stop()
            },
            { track?.flush() },
            { track?.release() },
            {
                if (headset?.playState == AudioTrack.PLAYSTATE_PLAYING) headset.stop()
            },
            { headset?.flush() },
            { headset?.release() },
            {
                if (request != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    audioManager.abandonAudioFocusRequest(request)
                }
            },
            {
                if (legacyListener != null) {
                    @Suppress("DEPRECATION")
                    audioManager.abandonAudioFocus(legacyListener)
                }
            },
            {
                if (unregisterDeviceCallback) {
                    audioManager.unregisterAudioDeviceCallback(audioDeviceCallback)
                }
            },
            {
                if (clearCommunicationRoute) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        audioManager.clearCommunicationDevice()
                    } else {
                        @Suppress("DEPRECATION")
                        audioManager.isSpeakerphoneOn = false
                    }
                }
            },
            {
                if (resetCommunicationMode) {
                    audioManager.mode = AudioManager.MODE_NORMAL
                }
            },
        )
    }

    private fun requestAudioFocus(
        attributes: AudioAttributes,
        run: PlaybackRunState,
    ): Boolean {
        communicationModeOwned = true
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            if ((change == AudioManager.AUDIOFOCUS_LOSS ||
                    change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) &&
                run.active && playbackRun === run && !interruptionReported
            ) {
                val shouldReport = synchronized(lifecycleLock) {
                    if (
                        playbackRun !== run ||
                        interruptionReported ||
                        !run.stop()
                    ) {
                        false
                    } else {
                        interruptionReported = true
                        audioFocusGranted = false
                        // Focus loss is terminal for this run. In particular,
                        // flushing must not call play() or accept more enqueue
                        // requests while Dart performs asynchronous teardown.
                        flushLocked(resumePlayback = false)
                        true
                    }
                }
                if (shouldReport) onInterruption()
            } else if (
                change == AudioManager.AUDIOFOCUS_GAIN &&
                run.active &&
                playbackRun === run
            ) {
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

    private fun registerAudioDeviceCallback() {
        if (audioDeviceCallbackRegistered) return
        audioDeviceCallbackRegistered = true
        audioManager.registerAudioDeviceCallback(audioDeviceCallback, Handler(Looper.getMainLooper()))
    }

    private fun refreshCommunicationRoute() = synchronized(lifecycleLock) {
        if (audioTrack != null) selectPreferredCommunicationDevice()
    }

    private fun selectPreferredCommunicationDevice() {
        communicationRouteOwned = true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val devices = audioManager.availableCommunicationDevices
            val preferredType = AudioRoutePolicy.preferredType(
                devices.map(AudioDeviceInfo::getType),
                audioManager.communicationDevice?.type,
            )
            val preferred = devices.firstOrNull {
                it.type == preferredType
            }
            if (preferred != null && audioManager.setCommunicationDevice(preferred)) {
                setLastOutputRoute(routeName(preferred.type))
            }
        } else {
            val outputTypes = audioManager
                .getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                .map(AudioDeviceInfo::getType)
            val hasExternal = AudioRoutePolicy.hasExternal(outputTypes)
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = !hasExternal
            if (!hasExternal) setLastOutputRoute("speaker")
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
        setLastOutputRoute(currentRoute)
    }

    private fun setLastOutputRoute(route: String) {
        if (route == "unknown" || route == lastOutputRoute) return
        lastOutputRoute = route
        onRouteChanged(route)
    }

    private fun clearQueue() = synchronized(queueLock) {
        queue.clear()
        queuedBytes = 0
    }

    companion object {
        private const val MAX_QUEUE_MILLISECONDS = 1_500
        private const val NON_BLOCKING_RETRY_MILLISECONDS = 2L
        private const val WORKER_JOIN_MILLISECONDS = 500L
    }

}
