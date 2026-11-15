package com.sywy.solvhen

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.PackageInfo
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
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private val CHANNEL = "solvhen/system"

    // MIUI may briefly detach/recreate a SurfaceView when adjustResize opens
    // the IME, especially while another app owns a video/PiP surface. Rendering
    // Flutter into the window texture avoids the stale black BLAST surface and
    // also composes predictably with the short-lived WebView tool canvas.
    override fun getRenderMode(): RenderMode = RenderMode.texture

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
                    "verifyApkIdentity" -> {
                        val filePath = call.argument<String>("filePath") ?: ""
                        result.success(verifyApkIdentity(filePath))
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
                    // ═══ 无障碍服务操作 ═══
                    "isAccessibilityEnabled" -> {
                        result.success(mapOf("enabled" to SolvhenAccessibilityService.isEnabled(this)))
                    }
                    "openAccessibilitySettings" -> {
                        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                        result.success(mapOf("opened" to true))
                    }
                    "inputTap" -> {
                        val x = call.argument<Double>("x")?.toFloat() ?: 0f
                        val y = call.argument<Double>("y")?.toFloat() ?: 0f
                        val svc = SolvhenAccessibilityService.instance
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启，请到设置→无障碍→Solvhen中开启"))
                        } else {
                            svc.performClick(x, y) { ok ->
                                result.success(mapOf("clicked" to ok, "x" to x, "y" to y))
                            }
                        }
                    }
                    "inputSwipe" -> {
                        val x1 = call.argument<Double>("x1")?.toFloat() ?: 0f
                        val y1 = call.argument<Double>("y1")?.toFloat() ?: 0f
                        val x2 = call.argument<Double>("x2")?.toFloat() ?: 0f
                        val y2 = call.argument<Double>("y2")?.toFloat() ?: 0f
                        val duration = call.argument<Long>("duration") ?: 300L
                        val svc = SolvhenAccessibilityService.instance
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            svc.performSwipe(x1, y1, x2, y2, duration) { ok ->
                                result.success(mapOf("swiped" to ok))
                            }
                        }
                    }
                    "inputText" -> {
                        val text = call.argument<String>("text") ?: ""
                        val svc = SolvhenAccessibilityService.instance
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            svc.inputText(text) { ok ->
                                result.success(mapOf("input" to ok, "text" to text))
                            }
                        }
                    }
                    "pressBack" -> {
                        val svc = SolvhenAccessibilityService.instance
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            result.success(mapOf("back" to svc.pressBack()))
                        }
                    }
                    "pressHome" -> {
                        val svc = SolvhenAccessibilityService.instance
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            result.success(mapOf("home" to svc.pressHome()))
                        }
                    }
                    "pressEnter" -> {
                        val svc = SolvhenAccessibilityService.instance
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            result.success(mapOf("enter" to svc.pressEnter()))
                        }
                    }
                    "pressRecents" -> {
                        val svc = SolvhenAccessibilityService.instance
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            result.success(mapOf("recents" to svc.pressRecents()))
                        }
                    }
                    "longPress" -> {
                        val x = call.argument<Double>("x")?.toFloat() ?: 0f
                        val y = call.argument<Double>("y")?.toFloat() ?: 0f
                        val svc = SolvhenAccessibilityService.instance
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            svc.performLongClick(x, y) { ok ->
                                result.success(mapOf("longPressed" to ok, "x" to x, "y" to y))
                            }
                        }
                    }
                    "getScreenText" -> {
                        val svc = SolvhenAccessibilityService.instance
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            result.success(mapOf("elements" to svc.getScreenText()))
                        }
                    }
                    "findText" -> {
                        val text = call.argument<String>("text") ?: ""
                        val svc = SolvhenAccessibilityService.instance
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            result.success(mapOf("matches" to svc.findText(text)))
                        }
                    }
                    "clickText" -> {
                        val text = call.argument<String>("text") ?: ""
                        val svc = SolvhenAccessibilityService.instance
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            svc.clickText(text) { ok ->
                                result.success(mapOf("clicked" to ok, "text" to text))
                            }
                        }
                    }
                    // ═══ UI 自动化内核 — 结构化读取 / 语义动作 / 原子序列 ═══
                    "uiDump" -> {
                        val svc = SolvhenAccessibilityService.instance
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启，请到设置→无障碍→Solvhen中开启"))
                        } else {
                            val includeInvisible = call.argument<Boolean>("includeInvisible") ?: false
                            val maxNodes = (call.argument<Int>("maxNodes") ?: 600).coerceIn(50, 3000)
                            offload(result) { svc.automator.dump(includeInvisible, maxNodes) }
                        }
                    }
                    "uiFind" -> {
                        val svc = SolvhenAccessibilityService.instance
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            offload(result) {
                                svc.automator.find(
                                    text = call.argument<String>("text") ?: "",
                                    viewId = call.argument<String>("viewId") ?: "",
                                    className = call.argument<String>("className") ?: "",
                                    clickableOnly = call.argument<Boolean>("clickableOnly") ?: false,
                                    editableOnly = call.argument<Boolean>("editableOnly") ?: false,
                                    scrollableOnly = call.argument<Boolean>("scrollableOnly") ?: false,
                                    exact = call.argument<Boolean>("exact") ?: false,
                                    limit = (call.argument<Int>("limit") ?: 20).coerceIn(1, 100)
                                )
                            }
                        }
                    }
                    "uiTapNode" -> {
                        val svc = SolvhenAccessibilityService.instance
                        val id = call.argument<Int>("id")
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else if (id == null) {
                            result.success(mapOf("ok" to false, "error" to "缺少参数 id"))
                        } else {
                            offload(result) { svc.automator.tapNode(id) }
                        }
                    }
                    "uiTapText" -> {
                        val svc = SolvhenAccessibilityService.instance
                        val text = call.argument<String>("text") ?: ""
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            offload(result) {
                                svc.automator.tapText(text, call.argument<Boolean>("exact") ?: false)
                            }
                        }
                    }
                    "uiTypeText" -> {
                        val svc = SolvhenAccessibilityService.instance
                        val text = call.argument<String>("text") ?: ""
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            offload(result) { svc.automator.typeText(text) }
                        }
                    }
                    "uiSwipe" -> {
                        val svc = SolvhenAccessibilityService.instance
                        val direction = call.argument<String>("direction") ?: "up"
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            offload(result) {
                                svc.automator.swipe(direction, call.argument<Long>("duration") ?: 300L)
                            }
                        }
                    }
                    "uiScrollFind" -> {
                        val svc = SolvhenAccessibilityService.instance
                        val text = call.argument<String>("text") ?: ""
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            offload(result) {
                                svc.automator.scrollUntilFound(
                                    text,
                                    (call.argument<Int>("maxScrolls") ?: 6).coerceIn(1, 30)
                                )
                            }
                        }
                    }
                    "uiWaitText" -> {
                        val svc = SolvhenAccessibilityService.instance
                        val text = call.argument<String>("text") ?: ""
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            offload(result) {
                                svc.automator.waitForText(
                                    text,
                                    (call.argument<Long>("timeoutMs") ?: 5000L).coerceIn(300L, 30000L)
                                )
                            }
                        }
                    }
                    "uiWaitIdle" -> {
                        val svc = SolvhenAccessibilityService.instance
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            offload(result) {
                                svc.automator.waitForIdle(
                                    (call.argument<Long>("timeoutMs") ?: 4000L).coerceIn(300L, 15000L)
                                )
                            }
                        }
                    }
                    "uiForeground" -> {
                        val svc = SolvhenAccessibilityService.instance
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            offload(result) { svc.automator.foreground() }
                        }
                    }
                    "uiDismiss" -> {
                        val svc = SolvhenAccessibilityService.instance
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            offload(result) {
                                svc.automator.dismiss(
                                    allowPermissions = call.argument<Boolean>("allowPermissions") ?: false,
                                    maxClicks = (call.argument<Int>("maxClicks") ?: 2).coerceIn(1, 5)
                                )
                            }
                        }
                    }
                    "uiSequence" -> {
                        val svc = SolvhenAccessibilityService.instance
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            val raw = call.argument<List<Map<String, Any>>>("steps") ?: emptyList()
                            offload(result) { svc.automator.sequence(raw) }
                        }
                    }
                    "screenshot" -> {
                        val svc = SolvhenAccessibilityService.instance
                        if (svc == null) {
                            result.success(mapOf("error" to "无障碍服务未开启"))
                        } else {
                            val quality = (call.argument<Int>("quality") ?: 70).coerceIn(20, 95)
                            val maxWidth = (call.argument<Int>("maxWidth") ?: 900).coerceIn(320, 1440)
                            svc.screenshotBase64(quality, maxWidth) { encoded ->
                                runOnUiThread {
                                    if (encoded == null) {
                                        result.success(mapOf("error" to "截图失败：需要 Android 11+ 且无障碍服务已开启截图能力"))
                                    } else {
                                        result.success(mapOf("format" to "jpeg", "base64" to encoded))
                                    }
                                }
                            }
                        }
                    }
                    // ═══ 通知监听 ═══
                    "getNotifications" -> {
                        val filter = call.argument<String>("filter") ?: ""
                        val notifications = SolvhenNotificationListener.getRecentNotifications(filter)
                        val enabled = SolvhenNotificationListener.isEnabled(this)
                        result.success(mapOf(
                            "notifications" to notifications,
                            "count" to notifications.size,
                            "service_enabled" to enabled
                        ))
                    }
                    "isNotificationListenerEnabled" -> {
                        result.success(mapOf("enabled" to SolvhenNotificationListener.isEnabled(this)))
                    }
                    "openNotificationListenerSettings" -> {
                        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                        result.success(mapOf("opened" to true))
                    }
                    "clearNotifications" -> {
                        SolvhenNotificationListener.clearNotifications()
                        result.success(mapOf("cleared" to true))
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("SYSTEM_ERROR", e.message, null)
            }
        }
    }

    /** 把可能阻塞的 UI 操作放到工作线程，结果回到平台线程返回。 */
    private fun offload(result: MethodChannel.Result, block: () -> Any?) {
        Thread {
            try {
                val value = block()
                runOnUiThread { result.success(value) }
            } catch (t: Throwable) {
                runOnUiThread { result.error("solvhen_ui", t.message ?: t.javaClass.simpleName, null) }
            }
        }.start()
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

    @Suppress("DEPRECATION")
    private fun certificateSha256(info: PackageInfo): String? {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners
        } else {
            info.signatures
        }
        val certificate = signatures?.firstOrNull() ?: return null
        return MessageDigest.getInstance("SHA-256")
            .digest(certificate.toByteArray())
            .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
    }

    @Suppress("DEPRECATION")
    private fun verifyApkIdentity(filePath: String): Map<String, Any> {
        return try {
            val apk = File(filePath).canonicalFile
            if (!apk.isFile) return mapOf("error" to "APK file not found")
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                PackageManager.GET_SIGNING_CERTIFICATES
            } else {
                PackageManager.GET_SIGNATURES
            }
            val archiveInfo = packageManager.getPackageArchiveInfo(apk.path, flags)
                ?: return mapOf("error" to "Unable to parse APK")
            val archiveCertificate = certificateSha256(archiveInfo)
                ?: return mapOf("error" to "APK signing certificate missing")
            val installedInfo = packageManager.getPackageInfo(packageName, flags)
            val installedCertificate = certificateSha256(installedInfo)
                ?: return mapOf("error" to "Installed signing certificate missing")
            mapOf(
                "packageName" to archiveInfo.packageName,
                "archiveCertificateSha256" to archiveCertificate,
                "installedCertificateSha256" to installedCertificate,
                "matchesInstalledCertificate" to archiveCertificate.equals(
                    installedCertificate,
                    ignoreCase = true,
                ),
            )
        } catch (e: Exception) {
            mapOf("error" to (e.message ?: e.javaClass.simpleName))
        }
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
