package com.streamapp.receiver

import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.WindowManager
import androidx.appcompat.app.AppCompatActivity
import com.streamapp.receiver.databinding.ActivityMainBinding
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RTCStatsReport
import org.webrtc.RendererCommon
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.VideoTrack
import org.webrtc.audio.JavaAudioDeviceModule

class MainActivity : AppCompatActivity(), SignalingClient.Listener {

    private lateinit var binding: ActivityMainBinding
    private lateinit var eglBase: EglBase
    private lateinit var peerConnectionFactory: PeerConnectionFactory

    private var pc: PeerConnection? = null
    private var signaling: SignalingClient? = null
    private var remoteVideoTrack: VideoTrack? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private var statsRunnable: Runnable? = null
    private var statsVisible = false
    private var prevFramesDecoded = 0L
    private var prevFramesDropped = 0L

    private val prefs by lazy { getSharedPreferences("stream_receiver", Context.MODE_PRIVATE) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        hideSystemBars()

        eglBase = EglBase.create()
        binding.videoRenderer.init(eglBase.eglBaseContext, null)
        binding.videoRenderer.setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FIT)
        binding.videoRenderer.setMirror(false)

        startPulseAnimation()

        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(applicationContext)
                .createInitializationOptions()
        )
        val audioDeviceModule = JavaAudioDeviceModule.builder(applicationContext)
            .createAudioDeviceModule()
        peerConnectionFactory = PeerConnectionFactory.builder()
            .setVideoDecoderFactory(DefaultVideoDecoderFactory(eglBase.eglBaseContext))
            .setAudioDeviceModule(audioDeviceModule)
            .createPeerConnectionFactory()

        binding.connectButton.setOnClickListener { onConnectClicked() }
        binding.changeServerButton.setOnClickListener { showServerEntry(prefill = true) }

        val savedAddress = prefs.getString(KEY_SERVER_ADDRESS, null)
        if (savedAddress.isNullOrBlank()) {
            showServerEntry(prefill = false)
        } else {
            binding.serverUrlText.text = savedAddress
            startSignaling(savedAddress, prefs.getString(KEY_SERVER_PASSWORD, null))
        }
    }

    private fun onConnectClicked() {
        val address = binding.serverAddressInput.text.toString().trim()
        if (address.isEmpty()) return
        val password = binding.serverPasswordInput.text.toString()
        prefs.edit()
            .putString(KEY_SERVER_ADDRESS, address)
            .putString(KEY_SERVER_PASSWORD, password)
            .apply()
        binding.serverUrlText.text = address
        binding.serverEntryError.text = ""
        binding.serverEntryOverlay.visibility = android.view.View.GONE
        binding.statusOverlay.visibility = android.view.View.VISIBLE
        startSignaling(address, password)
    }

    private fun showServerEntry(prefill: Boolean) {
        signaling?.disconnect()
        signaling = null
        closePeerConnection()
        if (prefill) {
            binding.serverAddressInput.setText(prefs.getString(KEY_SERVER_ADDRESS, ""))
            binding.serverPasswordInput.setText(prefs.getString(KEY_SERVER_PASSWORD, ""))
        }
        binding.serverEntryError.text = ""
        binding.statusOverlay.visibility = android.view.View.GONE
        binding.serverEntryOverlay.visibility = android.view.View.VISIBLE
    }

    private fun startSignaling(address: String, password: String?) {
        setStatus(getString(R.string.connecting))
        val url = if (address.startsWith("http")) address else "http://$address"
        val client = SignalingClient(url, password, this)
        signaling = client
        client.connect()
    }

    // --- SignalingClient.Listener ---------------------------------------------------

    override fun onConnected() {
        runOnUi { setStatus(getString(R.string.waiting_for_stream)) }
    }

    override fun onConnectError(message: String?) {
        runOnUi {
            if (message == "Incorrect password") {
                showServerEntry(prefill = true)
                binding.serverEntryError.text = "Incorrect password — try again"
            } else {
                setStatus(getString(R.string.cannot_reach_server))
            }
        }
    }

    override fun onJoinRejected(reason: String?) {
        runOnUi { setStatus(reason ?: "Could not join — room already in use") }
    }

    override fun onDisconnected() {
        runOnUi { setStatus(getString(R.string.cannot_reach_server)) }
    }

    override fun onOffer(sdp: String) {
        runOnUi {
            setStatus(getString(R.string.connecting))
            if (pc == null) createPeerConnection()
            val offerDesc = SessionDescription(SessionDescription.Type.OFFER, sdp)
            pc?.setRemoteDescription(object : SdpObserverAdapter() {
                override fun onSetSuccess() {
                    pc?.createAnswer(object : SdpObserverAdapter() {
                        override fun onCreateSuccess(answer: SessionDescription) {
                            pc?.setLocalDescription(object : SdpObserverAdapter() {
                                override fun onSetSuccess() {
                                    signaling?.sendAnswer(answer.description)
                                }
                            }, answer)
                        }
                    }, MediaConstraints())
                }
            }, offerDesc)
        }
    }

    override fun onIceCandidate(sdpMid: String?, sdpMLineIndex: Int, candidate: String) {
        runOnUi {
            pc?.addIceCandidate(IceCandidate(sdpMid, sdpMLineIndex, candidate))
        }
    }

    override fun onPeerDisconnected() {
        runOnUi {
            closePeerConnection()
            setStatus(getString(R.string.waiting_for_stream))
        }
    }

    // --- WebRTC ------------------------------------------------------------------

    private fun createPeerConnection() {
        val rtcConfig = PeerConnection.RTCConfiguration(emptyList())
        pc = peerConnectionFactory.createPeerConnection(rtcConfig, object : PeerConnection.Observer {
            override fun onSignalingChange(state: PeerConnection.SignalingState?) {}

            override fun onIceConnectionChange(state: PeerConnection.IceConnectionState?) {
                runOnUi {
                    when (state) {
                        PeerConnection.IceConnectionState.CONNECTED -> {
                            setStatus(null)
                            startStatsLoop()
                        }
                        PeerConnection.IceConnectionState.DISCONNECTED,
                        PeerConnection.IceConnectionState.FAILED -> {
                            stopStatsLoop()
                        }
                        else -> {}
                    }
                }
            }

            override fun onIceConnectionReceivingChange(receiving: Boolean) {}
            override fun onIceGatheringChange(state: PeerConnection.IceGatheringState?) {}

            override fun onIceCandidate(candidate: IceCandidate) {
                signaling?.sendIceCandidate(candidate.sdpMid, candidate.sdpMLineIndex, candidate.sdp)
            }

            override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {}

            override fun onAddStream(stream: MediaStream) {
                runOnUi { attachRemoteStream(stream) }
            }

            override fun onRemoveStream(stream: MediaStream?) {}
            override fun onDataChannel(channel: org.webrtc.DataChannel?) {}
            override fun onRenegotiationNeeded() {}
            override fun onAddTrack(receiver: org.webrtc.RtpReceiver?, streams: Array<out MediaStream>?) {}
        })
    }

    private fun attachRemoteStream(stream: MediaStream) {
        stream.videoTracks.firstOrNull()?.let { track ->
            remoteVideoTrack?.removeSink(binding.videoRenderer)
            remoteVideoTrack = track
            track.setEnabled(true)
            track.addSink(binding.videoRenderer)
        }
        stream.audioTracks.firstOrNull()?.setEnabled(true)
        setStatus(null)
    }

    private fun closePeerConnection() {
        stopStatsLoop()
        remoteVideoTrack?.removeSink(binding.videoRenderer)
        remoteVideoTrack = null
        pc?.close()
        pc = null
    }

    // --- Stats overlay -------------------------------------------------------------

    private fun startStatsLoop() {
        stopStatsLoop()
        prevFramesDecoded = 0
        prevFramesDropped = 0
        val runnable = object : Runnable {
            override fun run() {
                pollStats()
                mainHandler.postDelayed(this, 1000)
            }
        }
        statsRunnable = runnable
        mainHandler.post(runnable)
    }

    private fun stopStatsLoop() {
        statsRunnable?.let { mainHandler.removeCallbacks(it) }
        statsRunnable = null
    }

    private fun pollStats() {
        val connection = pc ?: return
        connection.getStats { report: RTCStatsReport ->
            var width = 0L
            var height = 0L
            var framesDecoded = 0L
            var framesDropped = 0L
            var codecName = "–"

            for (stats in report.statsMap.values) {
                if (stats.type == "inbound-rtp" && stats.members["kind"] == "video") {
                    width = longMember(stats.members, "frameWidth")
                    height = longMember(stats.members, "frameHeight")
                    framesDecoded = longMember(stats.members, "framesDecoded")
                    framesDropped = longMember(stats.members, "framesDropped")
                    val codecId = stats.members["codecId"] as? String
                    val codecStats = codecId?.let { report.statsMap[it] }
                    val mimeType = codecStats?.members?.get("mimeType") as? String
                    if (mimeType != null) codecName = mimeType.removePrefix("video/")
                }
            }

            val decodedDelta = (framesDecoded - prevFramesDecoded).coerceAtLeast(0)
            val droppedDelta = (framesDropped - prevFramesDropped).coerceAtLeast(0)
            prevFramesDecoded = framesDecoded
            prevFramesDropped = framesDropped

            val text = "${width}x${height}\n" +
                "$decodedDelta fps\n" +
                "dropped $droppedDelta/s\n" +
                "$codecName"

            runOnUi { binding.statsText.text = text }
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (binding.serverEntryOverlay.visibility != android.view.View.VISIBLE) {
            statsVisible = !statsVisible
            binding.statsText.visibility = if (statsVisible) android.view.View.VISIBLE else android.view.View.GONE
        }
        return super.onKeyDown(keyCode, event)
    }

    // --- UI helpers ------------------------------------------------------------------

    private fun startPulseAnimation() {
        ObjectAnimator.ofFloat(binding.pulseDot, "alpha", 0.3f, 1f).apply {
            duration = 700
            repeatMode = ValueAnimator.REVERSE
            repeatCount = ValueAnimator.INFINITE
            start()
        }
    }

    private fun setStatus(text: String?) {
        if (text == null) {
            binding.statusOverlay.visibility = android.view.View.GONE
        } else {
            binding.statusOverlay.visibility = android.view.View.VISIBLE
            binding.statusText.text = text
        }
    }

    private fun hideSystemBars() {
        window.decorView.systemUiVisibility = (
            android.view.View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or android.view.View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                or android.view.View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or android.view.View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or android.view.View.SYSTEM_UI_FLAG_FULLSCREEN
                or android.view.View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            )
    }

    private fun runOnUi(block: () -> Unit) {
        mainHandler.post(block)
    }

    override fun onDestroy() {
        super.onDestroy()
        stopStatsLoop()
        closePeerConnection()
        signaling?.disconnect()
        binding.videoRenderer.release()
        peerConnectionFactory.dispose()
        eglBase.release()
    }

    // WebRTC's native stats bridge can box numeric fields as Long, Int, or Double
    // depending on platform/version — normalize rather than risk a silent cast failure.
    private fun longMember(members: Map<String, Any>, key: String): Long {
        return when (val v = members[key]) {
            is Long -> v
            is Int -> v.toLong()
            is Double -> v.toLong()
            is String -> v.toLongOrNull() ?: 0L
            else -> 0L
        }
    }

    companion object {
        private const val KEY_SERVER_ADDRESS = "server_address"
        private const val KEY_SERVER_PASSWORD = "server_password"
    }
}

private abstract class SdpObserverAdapter : SdpObserver {
    open override fun onCreateSuccess(sdp: SessionDescription) {}
    open override fun onSetSuccess() {}
    open override fun onCreateFailure(error: String?) {}
    open override fun onSetFailure(error: String?) {}
}
