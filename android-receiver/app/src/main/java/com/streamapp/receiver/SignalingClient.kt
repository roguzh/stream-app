package com.streamapp.receiver

import android.util.Log
import io.socket.client.IO
import io.socket.client.Socket
import org.json.JSONObject

/**
 * Thin wrapper around the same Socket.io signaling protocol server.js speaks to the
 * browser receiver: join a single "stream" room, then relay offer/answer/ice-candidate
 * as raw JSON. The server never inspects these payloads, so this mirrors receiver.html
 * exactly rather than defining a new protocol.
 */
class SignalingClient(
    private val serverUrl: String,
    private val password: String?,
    private val listener: Listener
) {

    interface Listener {
        fun onConnected()
        fun onConnectError(message: String?)
        fun onDisconnected()
        fun onOffer(sdp: String)
        fun onIceCandidate(sdpMid: String?, sdpMLineIndex: Int, candidate: String)
        fun onPeerDisconnected()
        fun onJoinRejected(reason: String?)
    }

    private var socket: Socket? = null

    fun connect() {
        val opts = IO.Options().apply {
            reconnection = true
            reconnectionDelay = 1000
            reconnectionDelayMax = 5000
            // The server only checks this when STREAM_PASSWORD is set on its end —
            // harmless to always send, matches the web clients' auth.js behavior.
            auth = mapOf("password" to (password ?: ""))
        }
        val s = IO.socket(serverUrl, opts)
        socket = s

        s.on(Socket.EVENT_CONNECT) {
            val joinPayload = JSONObject().apply {
                put("room", ROOM)
                put("role", "receiver")
            }
            s.emit("join", joinPayload)
            listener.onConnected()
        }
        s.on(Socket.EVENT_CONNECT_ERROR) { args ->
            val message = args.getOrNull(0)?.let { arg ->
                (arg as? Exception)?.message ?: arg.toString()
            }
            Log.w(TAG, "connect_error: $message")
            listener.onConnectError(message)
        }
        s.on(Socket.EVENT_DISCONNECT) {
            listener.onDisconnected()
        }
        s.on("offer") { args ->
            val data = args.getOrNull(0) as? JSONObject ?: return@on
            listener.onOffer(data.getString("sdp"))
        }
        s.on("ice-candidate") { args ->
            val data = args.getOrNull(0) as? JSONObject ?: return@on
            val sdpMid = if (data.isNull("sdpMid")) null else data.optString("sdpMid", null)
            val sdpMLineIndex = data.optInt("sdpMLineIndex", 0)
            val candidate = data.optString("candidate", null) ?: return@on
            listener.onIceCandidate(sdpMid, sdpMLineIndex, candidate)
        }
        s.on("peer-disconnected") {
            listener.onPeerDisconnected()
        }
        s.on("join-rejected") { args ->
            val data = args.getOrNull(0) as? JSONObject
            listener.onJoinRejected(data?.optString("reason"))
        }

        s.connect()
    }

    fun sendAnswer(sdp: String) {
        val payload = JSONObject().apply {
            put("type", "answer")
            put("sdp", sdp)
        }
        socket?.emit("answer", payload)
    }

    fun sendIceCandidate(sdpMid: String?, sdpMLineIndex: Int, candidate: String) {
        val payload = JSONObject().apply {
            put("sdpMid", sdpMid)
            put("sdpMLineIndex", sdpMLineIndex)
            put("candidate", candidate)
        }
        socket?.emit("ice-candidate", payload)
    }

    fun disconnect() {
        socket?.off()
        socket?.disconnect()
        socket = null
    }

    private fun Array<Any>.getOrNull(index: Int): Any? = if (index < size) this[index] else null

    companion object {
        private const val TAG = "SignalingClient"
        private const val ROOM = "stream"
    }
}
