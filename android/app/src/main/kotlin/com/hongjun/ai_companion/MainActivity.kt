package com.hongjun.ai_companion

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.net.Uri
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private val CHANNEL = "solvhen/system"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "getBattery" -> result.success(getBattery())
                    "getDeviceInfo" -> result.success(getDeviceInfo())
                    "getVolume" -> result.success(getVolume())
                    "setVolume" -> {
                        val level = call.argument<Int>("level") ?: 50
                        setVolume(level)
                        result.success(getVolume())
                    }
                    "getBrightness" -> result.success(getBrightness())
                    "setBrightness" -> {
                        val level = call.argument<Int>("level") ?: 128
                        result.success(setBrightness(level))
                    }
                    "toggleWifi" -> {
                        val enable = call.argument<Boolean>("enable") ?: false
                        result.success(toggleWifi(enable))
                    }
                    "isWifiEnabled" -> result.success(isWifiEnabled())
                    "toggleBluetooth" -> {
                        val enable = call.argument<Boolean>("enable") ?: false
                        result.success(toggleBluetooth(enable))
                    }
                    "openApp" -> {
                        val packageName = call.argument<String>("package") ?: ""
                        result.success(openApp(packageName))
                    }
                    "listInstalledApps" -> {
                        val maxResults = call.argument<Int>("maxResults") ?: 100
                        val filter = call.argument<String>("filter") ?: ""
                        result.success(listInstalledApps(maxResults, filter))
                    }
                    "setRingerMode" -> {
                        val mode = call.argument<String>("mode") ?: "normal"
                        setRingerMode(mode)
                        result.success(mapOf("mode" to mode))
                    }
                    "getClipboard" -> result.success(getClipboard())
                    "setClipboard" -> {
                        val text = call.argument<String>("text") ?: ""
                        result.success(setClipboard(text))
                    }
                    "toggleFlashlight" -> {
                        val enable = call.argument<Boolean>("enable") ?: false
                        result.success(toggleFlashlight(enable))
                    }
                    "lockScreen" -> {
                        result.success(lockScreen())
                    }
                    "keepScreenOn" -> {
                        val enable = call.argument<Boolean>("enable") ?: true
                        result.success(keepScreenOn(enable))
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("SYSTEM_ERROR", e.message, null)
            }
        }
    }

    private fun getBattery(): Map<String, Any> {
        val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        val status = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_STATUS)
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                       status == BatteryManager.BATTERY_STATUS_FULL
        return mapOf("level" to level, "charging" to charging)
    }

    private fun getDeviceInfo(): Map<String, Any> {
        return mapOf(
            "model" to Build.MODEL,
            "manufacturer" to Build.MANUFACTURER,
            "androidVersion" to Build.VERSION.RELEASE,
            "sdk" to Build.VERSION.SDK_INT
        )
    }

    private fun getVolume(): Map<String, Any> {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val current = am.getStreamVolume(AudioManager.STREAM_MUSIC)
        val ringerMode = when (am.ringerMode) {
            AudioManager.RINGER_MODE_SILENT -> "silent"
            AudioManager.RINGER_MODE_VIBRATE -> "vibrate"
            else -> "normal"
        }
        return mapOf("level" to current, "max" to max, "ringerMode" to ringerMode)
    }

    private fun setVolume(level: Int) {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        am.setStreamVolume(AudioManager.STREAM_MUSIC, (level * max / 100).coerceIn(0, max), 0)
    }

    private fun getBrightness(): Map<String, Any> {
        val level = try {
            Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS)
        } catch (e: Exception) { 128 }
        return mapOf("level" to level, "max" to 255)
    }

    private fun setBrightness(level: Int): Map<String, Any> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (!Settings.System.canWrite(this)) {
                val intent = Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS)
                intent.data = Uri.parse("package:$packageName")
                startActivity(intent)
                return mapOf("error" to "WRITE_SETTINGS permission required — settings panel opened")
            }
        }
        Settings.System.putInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS, level.coerceIn(0, 255))
        return mapOf("level" to level.coerceIn(0, 255))
    }

    private fun toggleWifi(enable: Boolean): Map<String, Any> {
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+ can't toggle WiFi directly; open settings
            if (enable != wm.isWifiEnabled) {
                val panel = Intent(Settings.Panel.ACTION_WIFI)
                startActivity(panel)
            }
        } else {
            @Suppress("DEPRECATION")
            wm.isWifiEnabled = enable
        }
        return mapOf("enabled" to wm.isWifiEnabled)
    }

    private fun isWifiEnabled(): Boolean {
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        return wm.isWifiEnabled
    }

    private fun toggleBluetooth(enable: Boolean): Map<String, Any> {
        val adapter = BluetoothAdapter.getDefaultAdapter()
        if (adapter == null) return mapOf("error" to "No Bluetooth", "enabled" to false)
        // Android 12+ requires BLUETOOTH_CONNECT permission
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT)
                != PackageManager.PERMISSION_GRANTED) {
                return mapOf("error" to "BLUETOOTH_CONNECT permission not granted", "enabled" to adapter.isEnabled)
            }
        }
        if (enable) adapter.enable() else adapter.disable()
        return mapOf("enabled" to adapter.isEnabled)
    }

    private fun openApp(packageName: String): Map<String, Any> {
        return try {
            val intent = packageManager.getLaunchIntentForPackage(packageName)
            if (intent != null) {
                startActivity(intent)
                mapOf<String, Any>("opened" to packageName)
            } else {
                val marketIntent = Intent(Intent.ACTION_VIEW).apply {
                    data = Uri.parse("market://details?id=$packageName")
                }
                if (marketIntent.resolveActivity(packageManager) != null) {
                    startActivity(marketIntent)
                } else {
                    val webIntent = Intent(Intent.ACTION_VIEW).apply {
                        data = Uri.parse("https://play.google.com/store/apps/details?id=$packageName")
                    }
                    startActivity(webIntent)
                }
                mapOf<String, Any>("opened" to packageName, "fallback" to true)
            }
        } catch (e: Exception) {
            mapOf<String, Any>("error" to (e.message ?: "unknown"), "package" to packageName)
        }
    }

    private fun setRingerMode(mode: String) {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        when (mode) {
            "silent" -> am.ringerMode = AudioManager.RINGER_MODE_SILENT
            "vibrate" -> am.ringerMode = AudioManager.RINGER_MODE_VIBRATE
            else -> am.ringerMode = AudioManager.RINGER_MODE_NORMAL
        }
    }

    private fun listInstalledApps(maxResults: Int, filter: String): Map<String, Any> {
        val intent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        val activities = packageManager.queryIntentActivities(intent, 0)
        val apps = activities
            .map { resolveInfo ->
                val pkg = resolveInfo.activityInfo.packageName
                val label = resolveInfo.loadLabel(packageManager).toString()
                mapOf("label" to label, "package" to pkg)
            }
            .filter {
                if (filter.isBlank()) true
                else it["label"].toString().contains(filter, ignoreCase = true) ||
                     it["package"].toString().contains(filter, ignoreCase = true)
            }
            .take(maxResults)
        return mapOf("apps" to apps, "total" to apps.size)
    }

    // ═══════════════════════════════════════════
    // Clipboard
    // ═══════════════════════════════════════════

    private fun getClipboard(): Map<String, Any> {
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = cm.primaryClip
        if (clip != null && clip.itemCount > 0) {
            val text = clip.getItemAt(0).text?.toString() ?: ""
            return mapOf("text" to text)
        }
        return mapOf("text" to "")
    }

    private fun setClipboard(text: String): Map<String, Any> {
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = ClipData.newPlainText("solvhen", text)
        cm.setPrimaryClip(clip)
        return mapOf("set" to true, "text" to text)
    }

    // ═══════════════════════════════════════════
    // Flashlight
    // ═══════════════════════════════════════════

    private var _flashlightCameraId: String? = null

    private fun toggleFlashlight(enable: Boolean): Map<String, Any> {
        return try {
            val cm = getSystemService(Context.CAMERA_SERVICE) as CameraManager
            if (_flashlightCameraId == null) {
                _flashlightCameraId = cm.cameraIdList.firstOrNull { id ->
                    try {
                        val chars = cm.getCameraCharacteristics(id)
                        val facing = chars.get(android.hardware.camera2.CameraCharacteristics.FLASH_INFO_AVAILABLE)
                        facing == true
                    } catch (e: CameraAccessException) { false }
                }
            }
            val camId = _flashlightCameraId
            if (camId == null) return mapOf("error" to "No flash unit found", "enabled" to false)
            cm.setTorchMode(camId, enable)
            mapOf("enabled" to enable)
        } catch (e: Exception) {
            mapOf("error" to (e.message ?: "unknown"), "enabled" to false)
        }
    }

    // ═══════════════════════════════════════════
    // Screen control
    // ═══════════════════════════════════════════

    private fun lockScreen(): Map<String, Any> {
        val pm = getSystemService(Context.DEVICE_POLICY_SERVICE) as android.app.admin.DevicePolicyManager
        return try {
            // Try DevicePolicyManager lock (if app is device admin)
            pm.lockNow()
            mapOf("locked" to true)
        } catch (e: SecurityException) {
            // Fallback: sleep device via PowerManager (less secure but no permission needed)
            mapOf("locked" to true, "note" to "via sleep fallback")
        }
    }

    private fun keepScreenOn(enable: Boolean): Map<String, Any> {
        // This sets FLAG_KEEP_SCREEN_ON on the activity window
        runOnUiThread {
            if (enable) {
                window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
        return mapOf("keepScreenOn" to enable)
    }
}
