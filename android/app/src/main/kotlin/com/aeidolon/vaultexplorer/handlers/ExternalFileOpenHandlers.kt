package com.aeidolon.vaultexplorer.handlers

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.OpenableColumns
import androidx.documentfile.provider.DocumentFile
import com.aeidolon.vaultexplorer.MainActivity
import com.aeidolon.vaultexplorer.VeLog
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.ExecutorService

/** Opt-in ACTION_VIEW/ACTION_EDIT targets for the built-in file viewers. */
class ExternalFileOpenHandlers(
    private val activity: MainActivity,
    private val ioExecutor: ExecutorService,
) {
    private data class PendingOpen(
        val id: String,
        val uri: String,
        val displayName: String,
        val mimeType: String?,
        val viewer: String,
        val canWrite: Boolean,
    ) {
        fun toMap() = mapOf(
            "id" to id,
            "uri" to uri,
            "displayName" to displayName,
            "mimeType" to mimeType,
            "viewer" to viewer,
            "canWrite" to canWrite,
        )
    }

    companion object {
        private const val TAG = "ExternalFileOpen"
        private const val EDITOR_ALIAS = "com.aeidolon.vaultexplorer.OpenTextEditorAlias"
        private const val EDITOR_DECOY_ALIAS = "com.aeidolon.vaultexplorer.OpenTextEditorDecoyAlias"
        private const val MEDIA_ALIAS = "com.aeidolon.vaultexplorer.OpenMediaPlayerAlias"
        private const val MEDIA_DECOY_ALIAS = "com.aeidolon.vaultexplorer.OpenMediaPlayerDecoyAlias"
        private const val PDF_ALIAS = "com.aeidolon.vaultexplorer.OpenPdfViewerAlias"
        private const val PDF_DECOY_ALIAS = "com.aeidolon.vaultexplorer.OpenPdfViewerDecoyAlias"

        @Volatile private var pendingOpen: PendingOpen? = null
        @Volatile var channel: MethodChannel? = null

        private fun pair(viewer: String): Pair<String, String>? = when (viewer) {
            "editor" -> EDITOR_ALIAS to EDITOR_DECOY_ALIAS
            "media" -> MEDIA_ALIAS to MEDIA_DECOY_ALIAS
            "pdf" -> PDF_ALIAS to PDF_DECOY_ALIAS
            else -> null
        }

        /** Swap enabled handlers to labels matching the current app identity. */
        @JvmStatic
        fun syncIdentity(context: android.content.Context, decoyActive: Boolean) {
            val pm = context.packageManager
            for (viewer in listOf("editor", "media", "pdf")) {
                val (real, decoy) = pair(viewer) ?: continue
                val realName = ComponentName(context.packageName, real)
                val decoyName = ComponentName(context.packageName, decoy)
                val realEnabled = pm.getComponentEnabledSetting(realName) == PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                val decoyEnabled = pm.getComponentEnabledSetting(decoyName) == PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                if (!realEnabled && !decoyEnabled) continue
                val enable = if (decoyActive) decoyName else realName
                val disable = if (decoyActive) realName else decoyName
                runCatching {
                    pm.setComponentEnabledSetting(enable, PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP)
                    pm.setComponentEnabledSetting(disable, PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)
                }.onFailure { VeLog.w(TAG) { "Failed to sync $viewer handler identity: ${it.message}" } }
            }
        }
    }

    private fun component(name: String) = ComponentName(activity.packageName, name)

    fun handleSetEnabled(call: MethodCall, result: MethodChannel.Result) {
        val viewer = call.argument<String>("viewer")
        val enabled = call.argument<Boolean>("enabled") ?: false
        val names = pair(viewer ?: "")
        if (names == null) {
            result.error("INVALID_ARGS", "Unknown viewer", null)
            return
        }
        try {
            val decoyActive = DisguiseModeHandlers.isDecoyActive(activity)
            val wanted = if (decoyActive) names.second else names.first
            val other = if (decoyActive) names.first else names.second
            val pm = activity.packageManager
            pm.setComponentEnabledSetting(
                component(wanted),
                if (enabled) PackageManager.COMPONENT_ENABLED_STATE_ENABLED else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP,
            )
            pm.setComponentEnabledSetting(
                component(other),
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP,
            )
            result.success(null)
        } catch (e: Exception) {
            result.error("OPEN_WITH_UPDATE_FAILED", e.message, null)
        }
    }

    fun handleIsEnabled(call: MethodCall, result: MethodChannel.Result) {
        val names = pair(call.argument<String>("viewer") ?: "")
        if (names == null) {
            result.error("INVALID_ARGS", "Unknown viewer", null)
            return
        }
        val pm = activity.packageManager
        result.success(listOf(names.first, names.second).any { name ->
            pm.getComponentEnabledSetting(component(name)) == PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        })
    }

    fun handleCheckPending(call: MethodCall, result: MethodChannel.Result) {
        result.success(pendingOpen?.toMap())
    }

    fun handleAcknowledge(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        synchronized(this) {
            if (pendingOpen?.id == id) pendingOpen = null
        }
        result.success(null)
    }

    /** Called for ACTION_VIEW/ACTION_EDIT intents sent to one of our aliases. */
    fun handleIncomingIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW && intent?.action != Intent.ACTION_EDIT) return
        val uri = intent.data ?: return
        val scheme = uri.scheme?.lowercase()
        if (scheme != "content" && scheme != "file") return

        val canWrite = if (scheme == "file") {
            runCatching { java.io.File(uri.path ?: "").canWrite() }.getOrDefault(false)
        } else {
            (intent.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION) != 0
        }
        val requestedMime = intent.type
        ioExecutor.execute {
            try {
                val doc = runCatching { DocumentFile.fromSingleUri(activity, uri) }.getOrNull()
                val displayName = doc?.name
                    ?: queryDisplayName(uri)
                    ?: uri.lastPathSegment?.substringAfterLast('/')
                    ?: "document"
                val mimeType = requestedMime ?: runCatching { activity.contentResolver.getType(uri) }.getOrNull()
                val viewer = inferViewer(mimeType, displayName)
                val pending = PendingOpen(
                    UUID.randomUUID().toString(),
                    uri.toString(),
                    displayName,
                    mimeType,
                    viewer,
                    canWrite,
                )
                synchronized(this) { pendingOpen = pending }
                activity.runOnUiThread {
                    channel?.invokeMethod("onExternalFileOpenRequest", pending.toMap())
                }
            } catch (e: Exception) {
                VeLog.w(TAG) { "Couldn't prepare external open request: ${e.message}" }
            }
        }
    }

    private fun queryDisplayName(uri: Uri): String? = runCatching {
        activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    }.getOrNull()

    private fun inferViewer(mimeType: String?, name: String): String {
        val mime = mimeType?.lowercase().orEmpty()
        if (mime == "application/pdf" || name.endsWith(".pdf", ignoreCase = true)) return "pdf"
        if (mime.startsWith("image/") || mime.startsWith("audio/") || mime.startsWith("video/")) return "media"
        val ext = name.substringAfterLast('.', "").lowercase()
        if (ext in setOf(
                "jpg", "jpeg", "png", "gif", "webp", "avif", "heic",
                "mp4", "m4v", "webm", "mov", "avi", "mkv", "mpeg", "mpg",
                "flv", "ts", "wmv", "3gp", "vob", "ogv", "divx", "f4v", "m2ts",
                "mp3", "m4a", "wav", "flac", "ogg", "aac", "opus", "wma", "ac3", "eac3", "m4b", "ape", "aiff", "dts",
        )) return "media"
        return "editor"
    }

    fun handleGetExternalFileSize(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        if (uri == null) {
            result.error("INVALID_ARGS", "uri required", null)
            return
        }
        ioExecutor.execute {
            val size = try {
                val queried = activity.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else -1L
                } ?: -1L
                if (queried >= 0) queried else activity.contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: -1L
            } catch (_: Exception) { -1L }
            activity.runOnUiThread { result.success(size) }
        }
    }

    fun handleReadExternalFileChunk(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        val offset = (call.argument<Number>("offset") ?: 0).toLong()
        val length = call.argument<Int>("length") ?: 0
        if (uri == null || offset < 0 || length < 0) {
            result.error("INVALID_ARGS", "Invalid file range", null)
            return
        }
        ioExecutor.execute {
            val bytes = try {
                val pfd = activity.contentResolver.openFileDescriptor(uri, "r")
                if (pfd != null) {
                    pfd.use { descriptor ->
                        FileInputStream(descriptor.fileDescriptor).use { input ->
                            val channel = input.channel
                            channel.position(offset)
                            val buffer = ByteBuffer.allocate(length)
                            while (buffer.hasRemaining() && channel.read(buffer) > 0) Unit
                            buffer.flip()
                            ByteArray(buffer.remaining()).also { buffer.get(it) }
                        }
                    }
                } else null
            } catch (_: Exception) {
                runCatching {
                    activity.contentResolver.openInputStream(uri)?.use { input ->
                        var skipped = 0L
                        while (skipped < offset) {
                            val count = input.skip(offset - skipped)
                            if (count <= 0) break
                            skipped += count
                        }
                        val buffer = ByteArray(length)
                        var read = 0
                        while (read < length) {
                            val count = input.read(buffer, read, length - read)
                            if (count <= 0) break
                            read += count
                        }
                        buffer.copyOf(read)
                    }
                }.getOrNull()
            }
            activity.runOnUiThread { result.success(bytes) }
        }
    }

    fun handleWriteExternalFileChunk(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        val offset = (call.argument<Number>("offset") ?: 0).toLong()
        val data = call.argument<ByteArray>("data") ?: byteArrayOf()
        if (uri == null || offset < 0) {
            result.error("INVALID_ARGS", "Invalid file range", null)
            return
        }
        ioExecutor.execute {
            val success = try {
                try {
                    val mode = if (offset == 0L) "wt" else "rw"
                    val descriptor = activity.contentResolver.openFileDescriptor(uri, mode)
                        ?: throw java.io.IOException("Provider did not return a file descriptor")
                    descriptor.use { pfd ->
                        FileOutputStream(pfd.fileDescriptor).use { output ->
                            val fileChannel = output.channel
                            fileChannel.position(offset)
                            val buffer = ByteBuffer.wrap(data)
                            while (buffer.hasRemaining()) fileChannel.write(buffer)
                            fileChannel.force(true)
                        }
                    }
                } catch (descriptorFailure: Exception) {
                    // Some providers expose a stream but not a seekable file
                    // descriptor. Editor saves are sequential, so truncate
                    // once and append subsequent chunks in that case.
                    val streamMode = if (offset == 0L) "wt" else "wa"
                    activity.contentResolver.openOutputStream(uri, streamMode)?.use { output ->
                        output.write(data)
                    } ?: throw descriptorFailure
                }
                true
            } catch (e: Exception) {
                VeLog.w(TAG) { "Couldn't write external document: ${e.message}" }
                false
            }
            activity.runOnUiThread { result.success(success) }
        }
    }
}
