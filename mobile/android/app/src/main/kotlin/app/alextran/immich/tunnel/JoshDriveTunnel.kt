package app.alextran.immich.tunnel

import android.content.Context
import android.util.Log
import com.sun.jna.Library
import com.sun.jna.Native
import com.sun.jna.Pointer
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** The libsodium C functions the tunnel uses (libsodium.so ships in lazysodium-android). */
@Suppress("FunctionName")
interface Sodium : Library {
  fun sodium_init(): Int
  fun crypto_sign_seed_keypair(pk: ByteArray, sk: ByteArray, seed: ByteArray): Int
  fun crypto_sign_detached(sig: ByteArray, siglen: Pointer?, m: ByteArray, mlen: Long, sk: ByteArray): Int
  fun crypto_sign_verify_detached(sig: ByteArray, m: ByteArray, mlen: Long, pk: ByteArray): Int
  fun crypto_kx_keypair(pk: ByteArray, sk: ByteArray): Int
  fun crypto_kx_client_session_keys(rx: ByteArray, tx: ByteArray, cpk: ByteArray, csk: ByteArray, spk: ByteArray): Int
  fun crypto_secretstream_xchacha20poly1305_init_push(state: ByteArray, header: ByteArray, key: ByteArray): Int
  fun crypto_secretstream_xchacha20poly1305_push(
    state: ByteArray, c: ByteArray, clen: LongArray?, m: ByteArray, mlen: Long, ad: ByteArray?, adlen: Long, tag: Byte,
  ): Int
  fun crypto_secretstream_xchacha20poly1305_init_pull(state: ByteArray, header: ByteArray, key: ByteArray): Int
  fun crypto_secretstream_xchacha20poly1305_pull(
    state: ByteArray, m: ByteArray, mlen: LongArray?, tag: ByteArray, c: ByteArray, clen: Long, ad: ByteArray?, adlen: Long,
  ): Int
}

/**
 * JoshDrive end-to-end encrypted tunnel (Unrau fork). The app talks plain HTTP to 127.0.0.1:[PORT] on the
 * phone; each connection is carried as one WebSocket to wss://drive.unraujoshua.com/t, encrypted with
 * libsodium so Cloudflare only relays ciphertext. Protocol mirrors ~/immich/jd_gateway.py on the 910q:
 * signed ephemeral crypto_kx handshake (server key pinned here, device key registered there), then
 * secretstream XChaCha20-Poly1305, one message per frame.
 */
object JoshDriveTunnel {
  const val PORT = 48283
  private const val TAG = "JoshDriveTunnel"
  private const val URL = "wss://drive.unraujoshua.com/t"
  private val SERVER_SIGN_PK = hex("29d5110ef4bd304cf8ec5f3860fad43423df686f08ecf3f3e81ed0fd9256226b")
  private const val CHUNK = 64 * 1024
  private const val ABYTES = 17
  private const val TAG_MESSAGE: Byte = 0
  private const val TAG_FINAL: Byte = 3
  private const val STATE_BYTES = 64 // libsodium's state is 52 bytes; a little spare is harmless

  private val sodium: Sodium by lazy { Native.load("sodium", Sodium::class.java).also { it.sodium_init() } }
  private val http by lazy { OkHttpClient.Builder().pingInterval(25, TimeUnit.SECONDS).readTimeout(0, TimeUnit.MILLISECONDS).build() }
  @Volatile private var started = false
  private var devicePk = ByteArray(32)
  private var deviceSk = ByteArray(64)

  @Synchronized
  fun start(context: Context) {
    if (started) return
    try {
      loadDeviceKey(context)
      val server = ServerSocket(PORT, 64, InetAddress.getByName("127.0.0.1"))
      started = true
      Thread({
        while (true) {
          val socket = try { server.accept() } catch (e: Exception) { Log.w(TAG, "accept failed", e); continue }
          Thread({ relay(socket) }, "jd-tunnel-conn").apply { isDaemon = true }.start()
        }
      }, "jd-tunnel").apply { isDaemon = true }.start()
      Log.i(TAG, "listening on 127.0.0.1:$PORT, device ${hexOf(devicePk)}")
    } catch (e: Exception) {
      Log.w(TAG, "tunnel not started: ${e.message}")
    }
  }

  fun devicePublicKeyHex(context: Context): String {
    loadDeviceKey(context)
    return hexOf(devicePk)
  }

  @Synchronized
  private fun loadDeviceKey(context: Context) {
    if (deviceSk.any { it != 0.toByte() }) return
    val file = File(context.noBackupFilesDir, "joshdrive_device.seed")
    if (!file.exists()) {
      val seed = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
      file.writeBytes(seed)
    }
    sodium.crypto_sign_seed_keypair(devicePk, deviceSk, file.readBytes())
  }

  private fun relay(socket: Socket) {
    val ready = CountDownLatch(1)
    val pushState = ByteArray(STATE_BYTES)
    val pullState = ByteArray(STATE_BYTES)
    val cEphPk = ByteArray(32)
    val cEphSk = ByteArray(32)
    sodium.crypto_kx_keypair(cEphPk, cEphSk)
    val out = socket.getOutputStream()
    var stage = 0

    val listener = object : WebSocketListener() {
      override fun onOpen(webSocket: WebSocket, response: Response) {
        val ts = ByteBuffer.allocate(8).putLong(System.currentTimeMillis()).array()
        val signed = "JD1c".toByteArray() + cEphPk + ts + SERVER_SIGN_PK
        val sig = ByteArray(64)
        sodium.crypto_sign_detached(sig, null, signed, signed.size.toLong(), deviceSk)
        webSocket.send(("JD1".toByteArray() + cEphPk + devicePk + ts + sig).toByteString())
      }

      override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
        val frame = bytes.toByteArray()
        try {
          when (stage) {
            0 -> { // server's ephemeral key, signed with the pinned server key
              require(frame.size == 96) { "bad server reply" }
              val sEph = frame.copyOfRange(0, 32)
              val signed = "JD1s".toByteArray() + sEph + cEphPk
              require(sodium.crypto_sign_verify_detached(frame.copyOfRange(32, 96), signed, signed.size.toLong(), SERVER_SIGN_PK) == 0) {
                "server key mismatch"
              }
              val rx = ByteArray(32); val tx = ByteArray(32)
              require(sodium.crypto_kx_client_session_keys(rx, tx, cEphPk, cEphSk, sEph) == 0)
              val header = ByteArray(24)
              sodium.crypto_secretstream_xchacha20poly1305_init_push(pushState, header, tx)
              webSocket.send(header.toByteString())
              pullKey = rx
              stage = 1
            }
            1 -> { // server's stream header
              require(sodium.crypto_secretstream_xchacha20poly1305_init_pull(pullState, frame, pullKey) == 0)
              stage = 2
              ready.countDown()
            }
            else -> {
              val plain = ByteArray(frame.size - ABYTES)
              val tag = ByteArray(1)
              require(sodium.crypto_secretstream_xchacha20poly1305_pull(pullState, plain, null, tag, frame, frame.size.toLong(), null, 0) == 0) {
                "corrupt frame"
              }
              if (plain.isNotEmpty()) out.write(plain)
              if (tag[0] == TAG_FINAL) { out.flush(); socket.shutdownOutput() }
            }
          }
        } catch (e: Exception) {
          Log.w(TAG, "tunnel error: ${e.message}")
          webSocket.cancel(); socket.close(); ready.countDown()
        }
      }

      private var pullKey = ByteArray(32)
      override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(1000, null); runCatching { socket.close() }; ready.countDown() }
      override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { runCatching { socket.close() }; ready.countDown() }
    }

    val ws = http.newWebSocket(Request.Builder().url(URL).build(), listener)
    try {
      if (!ready.await(30, TimeUnit.SECONDS) || stage != 2) { ws.cancel(); socket.close(); return }
      val input = socket.getInputStream()
      val buffer = ByteArray(CHUNK)
      while (true) {
        val n = input.read(buffer)
        if (n < 0) break
        val plain = buffer.copyOf(n)
        val cipher = ByteArray(n + ABYTES)
        synchronized(pushState) {
          sodium.crypto_secretstream_xchacha20poly1305_push(pushState, cipher, null, plain, n.toLong(), null, 0, TAG_MESSAGE)
        }
        while (ws.queueSize() > 4L * 1024 * 1024) Thread.sleep(20) // back-pressure for big uploads
        if (!ws.send(cipher.toByteString())) break
      }
      val end = ByteArray(ABYTES)
      synchronized(pushState) {
        sodium.crypto_secretstream_xchacha20poly1305_push(pushState, end, null, ByteArray(0), 0, null, 0, TAG_FINAL)
      }
      ws.send(end.toByteString())
    } catch (e: Exception) {
      ws.cancel(); runCatching { socket.close() }
    }
  }

  private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
  private fun hexOf(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
}
