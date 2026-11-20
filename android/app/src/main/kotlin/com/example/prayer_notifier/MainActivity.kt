package com.example.prayer_notifier

import android.app.Activity
import android.content.Intent
import android.media.RingtoneManager
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "prayer/ringtone"
    private val requestCode = 4711
    private var pending: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "pick") {
                    if (pending != null) {
                        result.error("busy", "Picker already open", null)
                        return@setMethodCallHandler
                    }
                    pending = result
                    val current = call.argument<String>("current")
                    val intent = Intent(RingtoneManager.ACTION_RINGTONE_PICKER).apply {
                        putExtra(
                            RingtoneManager.EXTRA_RINGTONE_TYPE,
                            RingtoneManager.TYPE_ALARM or RingtoneManager.TYPE_NOTIFICATION or RingtoneManager.TYPE_RINGTONE
                        )
                        putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_SILENT, false)
                        putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_DEFAULT, true)
                        putExtra(RingtoneManager.EXTRA_RINGTONE_TITLE, "Choose prayer sound")
                        if (!current.isNullOrEmpty()) {
                            putExtra(RingtoneManager.EXTRA_RINGTONE_EXISTING_URI, Uri.parse(current))
                        }
                    }
                    startActivityForResult(intent, requestCode)
                } else {
                    result.notImplemented()
                }
            }
    }

    override fun onActivityResult(code: Int, resultCode: Int, data: Intent?) {
        if (code == requestCode) {
            val r = pending
            pending = null
            if (resultCode == Activity.RESULT_OK && data != null) {
                val uri = data.getParcelableExtra<Uri>(RingtoneManager.EXTRA_RINGTONE_PICKED_URI)
                if (uri != null) {
                    r?.success(mapOf("uri" to uri.toString(), "title" to titleOf(uri)))
                } else {
                    r?.success(null)
                }
            } else {
                r?.success(null)
            }
            return
        }
        super.onActivityResult(code, resultCode, data)
    }

    private fun titleOf(uri: Uri): String {
        return try {
            RingtoneManager.getRingtone(this, uri)?.getTitle(this) ?: "Custom sound"
        } catch (e: Exception) {
            "Custom sound"
        }
    }
}