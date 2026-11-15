package com.sywy.solvhen

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Solvhen 无障碍服务 — AI操控应用内部UI的核心
 * 
 * 启用方法：设置 → 无障碍 → Solvhen → 开启
 * 提供：点击/长按/滑动/输入文字/返回/主页/最近任务/读取屏幕内容
 */
class SolvhenAccessibilityService : AccessibilityService() {

    companion object {
        var instance: SolvhenAccessibilityService? = null
            private set

        /** 最近前台包名，供 Agent 判断当前所在应用 */
        @Volatile
        var lastPackage: String = ""
            private set

        internal fun rememberPackage(pkg: String?) {
            val value = pkg?.trim().orEmpty()
            if (value.isNotEmpty()) lastPackage = value
        }
        
        /** 检查无障碍服务是否已开启 */
        fun isEnabled(context: android.content.Context): Boolean {
            val enabledServices = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
            ) ?: return false
            return enabledServices.contains(context.packageName)
        }
    }

    /** UI 自动化内核：结构化读取 + 语义动作 + 原子序列 */
    val automator: SolvhenUiAutomator by lazy { SolvhenUiAutomator(this) }

    /** 最近一次无障碍事件的包名 */
    @Volatile
    var lastEventPackage: String = ""
        private set

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val pkg = event?.packageName?.toString()?.trim().orEmpty()
        if (pkg.isNotEmpty()) lastEventPackage = pkg
        rememberPackage(pkg)
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        super.onDestroy()
        instance = null
    }

    // ═══════════════════════════════════════════
    // 点击
    // ═══════════════════════════════════════════

    /** 点击指定坐标 */
    fun performClick(x: Float, y: Float, callback: (Boolean) -> Unit) {
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(
                Path().apply { moveTo(x, y) }, 0, 1
            ))
            .build()
        dispatchGesture(gesture, null, null)
        callback(true)
    }

    /** 长按指定坐标 */
    fun performLongClick(x: Float, y: Float, callback: (Boolean) -> Unit) {
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(
                Path().apply { moveTo(x, y) }, 0, 800
            ))
            .build()
        dispatchGesture(gesture, null, null)
        callback(true)
    }

    // ═══════════════════════════════════════════
    // 滑动
    // ═══════════════════════════════════════════

    /** 从 (x1,y1) 滑动到 (x2,y2) */
    fun performSwipe(x1: Float, y1: Float, x2: Float, y2: Float, duration: Long = 300, callback: (Boolean) -> Unit) {
        val path = Path().apply {
            moveTo(x1, y1)
            lineTo(x2, y2)
        }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, duration))
            .build()
        dispatchGesture(gesture, null, null)
        callback(true)
    }

    // ═══════════════════════════════════════════
    // 按键
    // ═══════════════════════════════════════════

    /** 按返回键 */
    fun pressBack(): Boolean {
        return performGlobalAction(GLOBAL_ACTION_BACK)
    }

    /** 按主页键 */
    fun pressHome(): Boolean {
        return performGlobalAction(GLOBAL_ACTION_HOME)
    }

    /** 打开最近任务 */
    fun pressRecents(): Boolean {
        return performGlobalAction(GLOBAL_ACTION_RECENTS)
    }

    /** 打开通知栏 */
    fun openNotifications(): Boolean {
        return performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
    }

    /** 打开快速设置 */
    fun openQuickSettings(): Boolean {
        return performGlobalAction(GLOBAL_ACTION_QUICK_SETTINGS)
    }

    /** 向当前焦点输入框发送回车键 */
    fun pressEnter(): Boolean {
        val root = rootInActiveWindow ?: return false
        val focused = findFocusedEditable(root)
        if (focused != null) {
            // 使用 ACTION_NEXT_AT_MOVEMENT_GRANULARITY 模拟换行/确认
            val args = Bundle()
            args.putInt(
                AccessibilityNodeInfo.ACTION_ARGUMENT_MOVEMENT_GRANULARITY_INT,
                AccessibilityNodeInfo.MOVEMENT_GRANULARITY_LINE
            )
            return focused.performAction(
                AccessibilityNodeInfo.ACTION_NEXT_AT_MOVEMENT_GRANULARITY, args
            )
        }
        return false
    }

    // ═══════════════════════════════════════════
    // 文字输入
    // ═══════════════════════════════════════════

    /** 向当前焦点输入框输入文字（SET_TEXT 方式，适合搜索框等） */
    fun inputText(text: String, callback: (Boolean) -> Unit) {
        val root = rootInActiveWindow ?: run { callback(false); return }
        val focused = findFocusedEditable(root)
        if (focused != null) {
            val args = Bundle()
            args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
            val ok = focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
            callback(ok)
        } else {
            callback(false)
        }
    }

    // ═══════════════════════════════════════════
    // 屏幕内容读取
    // ═══════════════════════════════════════════

    /** 读取当前屏幕上的所有可见文本 */
    fun getScreenText(): List<Map<String, Any>> {
        val root = rootInActiveWindow ?: return emptyList()
        val items = mutableListOf<Map<String, Any>>()
        collectTextNodes(root, items, 0)
        return items
    }

    /** 查找包含指定文字的节点 */
    fun findText(text: String): List<Map<String, Any>> {
        val root = rootInActiveWindow ?: return emptyList()
        return findByText(root, text)
    }

    /** 点击包含指定文字的元素 */
    fun clickText(text: String, callback: (Boolean) -> Unit) {
        val root = rootInActiveWindow ?: run { callback(false); return }
        val nodes = findNodesByText(root, text)
        for (node in nodes) {
            if (node.isClickable) {
                val ok = node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                if (ok) { callback(true); return }
            }
        }
        callback(false)
    }

    // ═══════════════════════════════════════════
    // 截图 — 让视觉模型也能「看」屏幕
    // ═══════════════════════════════════════════

    /** 截取当前屏幕并返回 Base64 JPEG。需要 Android 11(API 30)+ 且清单声明 canTakeScreenshot。 */
    fun screenshotBase64(quality: Int = 70, maxWidth: Int = 900, callback: (String?) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            callback(null)
            return
        }
        try {
            takeScreenshot(Display.DEFAULT_DISPLAY, mainExecutor, object : TakeScreenshotCallback {
                override fun onSuccess(screenshot: ScreenshotResult) {
                    val buffer = screenshot.hardwareBuffer
                    try {
                        val bitmap = Bitmap.wrapHardwareBuffer(buffer, screenshot.colorSpace)
                        if (bitmap == null) {
                            callback(null)
                            return
                        }
                        val out = ByteArrayOutputStream()
                        scaleDown(bitmap, maxWidth).compress(Bitmap.CompressFormat.JPEG, quality, out)
                        callback(Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP))
                    } catch (t: Throwable) {
                        callback(null)
                    } finally {
                        try { buffer?.close() } catch (_: Throwable) {}
                    }
                }

                override fun onFailure(errorCode: Int) {
                    callback(null)
                }
            })
        } catch (t: Throwable) {
            callback(null)
        }
    }

    private fun scaleDown(source: Bitmap, maxWidth: Int): Bitmap {
        if (source.width <= maxWidth) return source
        val ratio = maxWidth.toFloat() / source.width
        return Bitmap.createScaledBitmap(source, maxWidth, (source.height * ratio).toInt(), true)
    }

    // ═══════════════════════════════════════════
    // 辅助方法
    // ═══════════════════════════════════════════

    private fun findFocusedEditable(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (node.isFocused && node.isEditable) return node
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findFocusedEditable(child)
            if (found != null) return found
        }
        return null
    }

    private fun collectTextNodes(node: AccessibilityNodeInfo, items: MutableList<Map<String, Any>>, depth: Int) {
        if (depth > 20) return
        val text = node.text?.toString()?.trim() ?: ""
        val contentDesc = node.contentDescription?.toString()?.trim() ?: ""
        val display = when {
            text.isNotEmpty() -> text
            contentDesc.isNotEmpty() -> contentDesc
            else -> ""
        }
        if (display.isNotEmpty()) {
            val rect = Rect()
            node.getBoundsInScreen(rect)
            items.add(mapOf(
                "text" to display,
                "clickable" to node.isClickable,
                "editable" to node.isEditable,
                "class" to (node.className?.toString() ?: ""),
                "bounds" to mapOf("x" to rect.centerX(), "y" to rect.centerY(), 
                    "left" to rect.left, "top" to rect.top, "right" to rect.right, "bottom" to rect.bottom)
            ))
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            collectTextNodes(child, items, depth + 1)
        }
    }

    private fun findByText(node: AccessibilityNodeInfo, query: String): List<Map<String, Any>> {
        val results = mutableListOf<Map<String, Any>>()
        findTextInNode(node, query, results, 0)
        return results
    }

    private fun findTextInNode(node: AccessibilityNodeInfo, query: String, results: MutableList<Map<String, Any>>, depth: Int) {
        if (depth > 20) return
        val text = node.text?.toString() ?: ""
        val desc = node.contentDescription?.toString() ?: ""
        if (text.contains(query, ignoreCase = true) || desc.contains(query, ignoreCase = true)) {
            val rect = Rect()
            node.getBoundsInScreen(rect)
            results.add(mapOf(
                "text" to text,
                "desc" to desc,
                "clickable" to node.isClickable,
                "bounds" to mapOf("x" to rect.centerX(), "y" to rect.centerY(),
                    "left" to rect.left, "top" to rect.top, "right" to rect.right, "bottom" to rect.bottom)
            ))
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            findTextInNode(child, query, results, depth + 1)
        }
    }

    private fun findNodesByText(node: AccessibilityNodeInfo, text: String): List<AccessibilityNodeInfo> {
        val results = mutableListOf<AccessibilityNodeInfo>()
        findNodesRecursive(node, text, results, 0)
        return results
    }

    private fun findNodesRecursive(node: AccessibilityNodeInfo, text: String, results: MutableList<AccessibilityNodeInfo>, depth: Int) {
        if (depth > 20) return
        val nodeText = node.text?.toString() ?: ""
        val desc = node.contentDescription?.toString() ?: ""
        if (nodeText.contains(text, ignoreCase = true) || desc.contains(text, ignoreCase = true)) {
            results.add(node)
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            findNodesRecursive(child, text, results, depth + 1)
        }
    }
}
