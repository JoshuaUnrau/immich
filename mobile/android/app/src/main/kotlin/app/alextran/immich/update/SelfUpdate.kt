package app.alextran.immich.update

import android.Manifest
import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import app.alextran.immich.R
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/**
 * Self-updates this build of Immich (Unrau fork) from Josh's own download site. Only a newer
 * versionCode, hash-matched and signed with the same key as the installed app, is ever installed.
 * The first install from the site asks once; after that Immich is the installer of record and
 * Android 12+ applies updates without asking.
 */
object SelfUpdate {
  private const val TAG = "SelfUpdate"
  private const val SITE = "https://michelle-thinkcentre-m910q.tail0ffed4.ts.net:10000/pocket-codex/"
  private const val FEED = SITE + "immich-update.json"
  private const val CHANNEL = "immich_updates"
  private const val NOTIFICATION_ID = 7302
  private const val MAX_APK_BYTES = 400L * 1024 * 1024

  fun schedule(context: Context) {
    val online = Constraints.Builder().setRequiredNetworkType(NetworkType.UNMETERED).build()
    val work = WorkManager.getInstance(context)
    work.enqueueUniquePeriodicWork(
      "immich_self_update",
      ExistingPeriodicWorkPolicy.KEEP,
      PeriodicWorkRequestBuilder<UpdateWorker>(12, TimeUnit.HOURS).setConstraints(online)
        .setInitialDelay(12, TimeUnit.HOURS).build(),
    )
    work.enqueueUniqueWork(
      "immich_self_update_now",
      ExistingWorkPolicy.KEEP,
      OneTimeWorkRequestBuilder<UpdateWorker>().setConstraints(online).build(),
    )
  }

  @Synchronized
  internal fun check(context: Context) {
    val feed = JSONObject(String(fetch(FEED, 64 * 1024), Charsets.UTF_8))
    val version = feed.getLong("versionCode")
    if (version <= installedCode(context)) return
    val url = feed.getString("apkUrl")
    val digest = feed.getString("sha256").lowercase()
    require(url.startsWith(SITE) && url.endsWith(".apk") && digest.matches(Regex("[0-9a-f]{64}"))) { "Invalid update feed" }

    if (!context.packageManager.canRequestPackageInstalls()) {
      notify(context, "Allow JoshDrive to install its updates",
        "JoshDrive ${feed.optString("versionName")} is available. Tap to turn on \"Install unknown apps\" for JoshDrive.",
        PendingIntent.getActivity(context, 0,
          Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + context.packageName))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
          PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
      return
    }

    val apk = File(context.cacheDir, "immich-update.apk")
    if (sha256(apk) != digest) {
      val temp = File(context.cacheDir, "immich-update.tmp")
      download(url, temp)
      if (sha256(temp) != digest) { temp.delete(); error("Update digest mismatch") }
      if (!temp.renameTo(apk)) error("Could not save update")
    }
    if (!sameSignerNewer(context, apk, version)) { apk.delete(); error("Update signer or version mismatch") }
    if (inUse()) {
      // Installing closes the app; never do that while Josh is looking at it. Try again shortly.
      WorkManager.getInstance(context).enqueueUniqueWork(
        "immich_self_update_retry",
        ExistingWorkPolicy.REPLACE,
        OneTimeWorkRequestBuilder<UpdateWorker>().setInitialDelay(20, TimeUnit.MINUTES).build(),
      )
      return
    }
    install(context, apk, feed.optString("versionName", version.toString()))
  }

  private fun install(context: Context, apk: File, versionName: String) {
    val installer = context.packageManager.packageInstaller
    val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
      .apply {
        setAppPackageName(context.packageName)
        if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
      }
    val sessionId = installer.createSession(params)
    installer.openSession(sessionId).use { session ->
      apk.inputStream().use { input ->
        session.openWrite("immich.apk", 0, apk.length()).use { out ->
          input.copyTo(out)
          session.fsync(out)
        }
      }
      val status = Intent(context, InstallResultReceiver::class.java).putExtra("versionName", versionName)
      val flags = PendingIntent.FLAG_UPDATE_CURRENT or
        (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
      session.commit(PendingIntent.getBroadcast(context, sessionId, status, flags).intentSender)
    }
  }

  private fun inUse(): Boolean {
    val state = ActivityManager.RunningAppProcessInfo()
    ActivityManager.getMyMemoryState(state)
    return state.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE
  }

  internal fun notify(context: Context, title: String, text: String, tap: PendingIntent?) {
    val manager = context.getSystemService(NotificationManager::class.java) ?: return
    if (Build.VERSION.SDK_INT >= 26) {
      manager.createNotificationChannel(NotificationChannel(CHANNEL, "App updates", NotificationManager.IMPORTANCE_LOW))
    }
    if (Build.VERSION.SDK_INT >= 33 &&
      context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
    val builder = NotificationCompat.Builder(context, CHANNEL)
      .setSmallIcon(R.drawable.notification_icon)
      .setContentTitle(title)
      .setContentText(text)
      .setStyle(NotificationCompat.BigTextStyle().bigText(text))
      .setAutoCancel(true)
    if (tap != null) builder.setContentIntent(tap)
    manager.notify(NOTIFICATION_ID, builder.build())
  }

  private fun fetch(url: String, limit: Int): ByteArray {
    val connection = open(url)
    try {
      val bytes = connection.inputStream.use { it.readNBytesCompat(limit + 1) }
      require(bytes.size <= limit) { "Feed too large" }
      return bytes
    } finally {
      connection.disconnect()
    }
  }

  private fun download(url: String, target: File) {
    val connection = open(url)
    try {
      var total = 0L
      connection.inputStream.use { input ->
        target.outputStream().use { out ->
          val buffer = ByteArray(64 * 1024)
          while (true) {
            val n = input.read(buffer)
            if (n < 0) break
            total += n
            require(total <= MAX_APK_BYTES) { "Update too large" }
            out.write(buffer, 0, n)
          }
          out.fd.sync()
        }
      }
    } finally {
      connection.disconnect()
    }
  }

  private fun open(url: String): HttpURLConnection =
    (URL(url).openConnection() as HttpURLConnection).apply {
      instanceFollowRedirects = false
      connectTimeout = 15_000
      readTimeout = 60_000
      if (responseCode != 200) { disconnect(); error("HTTP $responseCode for $url") }
    }

  private fun java.io.InputStream.readNBytesCompat(max: Int): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    val buffer = ByteArray(8192)
    while (out.size() < max) {
      val n = read(buffer, 0, minOf(buffer.size, max - out.size()))
      if (n < 0) break
      out.write(buffer, 0, n)
    }
    return out.toByteArray()
  }

  private fun sha256(file: File): String {
    if (!file.isFile) return ""
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { input ->
      val buffer = ByteArray(64 * 1024)
      while (true) {
        val n = input.read(buffer)
        if (n < 0) break
        digest.update(buffer, 0, n)
      }
    }
    return digest.digest().joinToString("") { "%02x".format(it) }
  }

  private fun installedCode(context: Context): Long {
    val info = context.packageManager.getPackageInfo(context.packageName, 0)
    return if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
  }

  private fun sameSignerNewer(context: Context, apk: File, expectedVersion: Long): Boolean {
    val pm = context.packageManager
    val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
    val installed = pm.getPackageInfo(context.packageName, flags)
    val archive: PackageInfo = pm.getPackageArchiveInfo(apk.absolutePath, flags) ?: return false
    if (archive.packageName != context.packageName) return false
    val archiveVersion = if (Build.VERSION.SDK_INT >= 28) archive.longVersionCode else archive.versionCode.toLong()
    if (archiveVersion != expectedVersion || archiveVersion <= installedCode(context)) return false
    @Suppress("DEPRECATION")
    val current = if (Build.VERSION.SDK_INT >= 28) installed.signingInfo?.apkContentsSigners else installed.signatures
    @Suppress("DEPRECATION")
    val next = if (Build.VERSION.SDK_INT >= 28) archive.signingInfo?.apkContentsSigners else archive.signatures
    return current != null && next != null && current.isNotEmpty() && current.contentEquals(next)
  }
}

class UpdateWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
  override fun doWork(): Result =
    try {
      SelfUpdate.check(applicationContext)
      Result.success()
    } catch (e: Exception) {
      // Offline, site down or a failed verification never bothers Josh; the next run tries again.
      Log.w("SelfUpdate", "Update check failed: ${e.message}")
      Result.success()
    }
}

class InstallResultReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    val version = intent.getStringExtra("versionName") ?: ""
    when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
      PackageInstaller.STATUS_PENDING_USER_ACTION -> {
        @Suppress("DEPRECATION")
        val confirm = (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
          else intent.getParcelableExtra(Intent.EXTRA_INTENT)) ?: return
        confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        SelfUpdate.notify(context, "JoshDrive $version is ready", "Tap to install the verified update.",
          PendingIntent.getActivity(context, 1, confirm, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
      }
      PackageInstaller.STATUS_SUCCESS -> {
        File(context.cacheDir, "immich-update.apk").delete()
        SelfUpdate.notify(context, "JoshDrive updated to $version", "Installed automatically from your server.",
          context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
            PendingIntent.getActivity(context, 2, it, PendingIntent.FLAG_IMMUTABLE)
          })
      }
      else -> Log.w("SelfUpdate", "Install failed: ${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)}")
    }
  }
}
