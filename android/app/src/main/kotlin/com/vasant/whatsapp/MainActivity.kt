package com.vasant.whatsapp

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import java.io.File
import java.io.FileOutputStream
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.vasant.whatsapp/overlay"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasPermission" -> result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)
                    )
                    "openSettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
                        }
                        result.success(null)
                    }
                    "startBubble" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(Intent(this, FloatingBubbleService::class.java))
                        } else {
                            startService(Intent(this, FloatingBubbleService::class.java))
                        }
                        result.success(null)
                    }
                    "stopBubble" -> {
                        stopService(Intent(this, FloatingBubbleService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.vasant.whatsapp/diagnostics")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveCrashReport" -> {
                        val content = call.argument<String>("content") ?: ""
                        val replace = call.argument<Boolean>("replace") ?: false
                        try {
                            saveCrashReportToDownloads(content, replace)
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("DOWNLOAD_WRITE_FAILED", error.message, null)
                        }
                    }
                    "clearCrashReport" -> {
                        try {
                            clearCrashReportFromDownloads()
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("DOWNLOAD_CLEAR_FAILED", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun saveCrashReportToDownloads(content: String, replace: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = contentResolver
            val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
            val relativePath = Environment.DIRECTORY_DOWNLOADS + "/WhatsReply/"
            val projection = arrayOf(MediaStore.Downloads._ID)
            val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ? AND " +
                "${MediaStore.Downloads.RELATIVE_PATH} = ?"
            val args = arrayOf("crash_reports.txt", relativePath)
            var uri: Uri? = null
            resolver.query(collection, projection, selection, args, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val id = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.Downloads._ID))
                    uri = Uri.withAppendedPath(collection, id.toString())
                }
            }
            if (uri == null) {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, "crash_reports.txt")
                    put(MediaStore.Downloads.MIME_TYPE, "text/plain")
                    put(MediaStore.Downloads.RELATIVE_PATH, relativePath)
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                uri = resolver.insert(collection, values)
                    ?: throw IllegalStateException("Unable to create Downloads/crash_reports.txt")
            }
            resolver.openOutputStream(uri!!, if (replace) "wt" else "wa")?.use { output ->
                output.write(content.toByteArray(Charsets.UTF_8))
            } ?: throw IllegalStateException("Unable to open crash report")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.IS_PENDING, 0)
                }
                resolver.update(uri!!, values, null, null)
            }
        } else {
            val directory = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                "WhatsReply",
            )
            if (!directory.exists() && !directory.mkdirs()) {
                throw IllegalStateException("Unable to create Downloads/WhatsReply")
            }
            FileOutputStream(File(directory, "crash_reports.txt"), !replace).use { output ->
                output.write(content.toByteArray(Charsets.UTF_8))
            }
        }
    }

    private fun clearCrashReportFromDownloads() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ? AND " +
                "${MediaStore.Downloads.RELATIVE_PATH} = ?"
            val args = arrayOf(
                "crash_reports.txt",
                Environment.DIRECTORY_DOWNLOADS + "/WhatsReply/",
            )
            contentResolver.delete(MediaStore.Downloads.EXTERNAL_CONTENT_URI, selection, args)
        } else {
            File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                "WhatsReply/crash_reports.txt",
            ).delete()
        }
    }
}
