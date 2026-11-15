package com.sywy.solvhen

import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Solvhen UI 自动化内核 —— 让 Agent 真正「看懂」并「操作」手机界面。
 *
 * 设计要点（参照 Mika 的 on-device agent 思路 + Solvhen 现有安全模型）：
 *  1. 结构化 UI 树：每次 dump 给节点分配稳定 id，Agent 用 id 精准点击，
 *     避免「同名文字点错」这一最常见失败。
 *  2. 语义动作优先：能点节点就用 ACTION_CLICK，点不动才回退到坐标手势。
 *  3. 等待而不是盲打：waitForText / waitForIdle 让每一步都有确认。
 *  4. 滚动查找：目标在屏幕外时自己滚，而不是让模型反复猜坐标。
 *  5. 原子序列：一次确认执行多步，避免逐步往返造成的界面漂移。
 *
 * ⚠️ 本类不持有 Android 权限，全部动作经 SolvhenAccessibilityService 的
 *    已授权能力完成；策略与确认仍由 Dart 侧 ToolPolicyEngine 决定。
 */
class SolvhenUiAutomator(private val service: SolvhenAccessibilityService) {

    companion object {
        private const val MAX_DEPTH = 40
        private const val DEFAULT_MAX_NODES = 600

        /** 安全关闭类文案：优先点这些，绝不主动点「允许」。 */
        private val SAFE_DISMISS = listOf(
            "取消", "关闭", "以后再说", "稍后", "跳过", "暂不", "不同意", "拒绝",
            "Cancel", "Close", "Not now", "Later", "Skip", "No thanks", "Dismiss"
        )

        /** 仅在显式授权时才点：用于「允许」类权限框。 */
        private val PERMISSION_ACCEPT = listOf(
            "允许", "始终允许", "仅在使用中允许", "同意", "Allow", "While using the app", "OK"
        )
    }

    private val refs = LinkedHashMap<Int, AccessibilityNodeInfo>()
    private var nextId = 1

    private fun reset() {
        refs.clear()
        nextId = 1
    }

    // ═══════════════════════════════════════════════════════
    // 1. 结构化 UI 树
    // ═══════════════════════════════════════════════════════

    fun dump(includeInvisible: Boolean = false, maxNodes: Int = DEFAULT_MAX_NODES): Map<String, Any> {
        reset()
        val root = service.rootInActiveWindow
            ?: return linkedMapOf("error" to "读不到当前窗口：请确认无障碍服务已开启，且屏幕未锁", "count" to 0)
        val out = mutableListOf<Map<String, Any>>()
        var visited = 0
        walk(root, 0) { node, depth ->
            if (visited >= maxNodes) return@walk false
            visited++
            if (!includeInvisible && !node.isVisibleToUser) return@walk true
            val text = node.text?.toString()?.trim().orEmpty()
            val desc = node.contentDescription?.toString()?.trim().orEmpty()
            val meaningful = text.isNotEmpty() || desc.isNotEmpty() || node.isClickable ||
                node.isEditable || node.isScrollable || node.isCheckable
            if (meaningful) {
                val id = nextId++
                refs[id] = node
                out.add(entry(id, node, depth))
            }
            true
        }
        return linkedMapOf(
            "package" to (root.packageName?.toString().orEmpty()),
            "window" to activeWindowTitle(),
            "count" to out.size,
            "nodes" to out
        )
    }

    // ═══════════════════════════════════════════════════════
    // 2. 条件查找
    // ═══════════════════════════════════════════════════════

    fun find(
        text: String = "",
        viewId: String = "",
        className: String = "",
        clickableOnly: Boolean = false,
        editableOnly: Boolean = false,
        scrollableOnly: Boolean = false,
        exact: Boolean = false,
        limit: Int = 20
    ): Map<String, Any> {
        reset()
        val root = service.rootInActiveWindow
            ?: return linkedMapOf("error" to "读不到当前窗口", "count" to 0, "matches" to emptyList<Map<String, Any>>())
        val hits = mutableListOf<Map<String, Any>>()
        walk(root, 0) { node, depth ->
            if (hits.size >= limit) return@walk false
            if (!node.isVisibleToUser) return@walk true
            val t = node.text?.toString()?.trim().orEmpty()
            val d = node.contentDescription?.toString()?.trim().orEmpty()
            val vid = node.viewIdResourceName?.substringAfterLast('/') ?: ""
            val cls = node.className?.toString()?.substringAfterLast('.') ?: ""
            val textOk = text.isEmpty() || (if (exact) {
                t.equals(text, true) || d.equals(text, true)
            } else {
                t.contains(text, true) || d.contains(text, true)
            })
            val ok = textOk &&
                (viewId.isEmpty() || vid.equals(viewId, true)) &&
                (className.isEmpty() || cls.equals(className, true)) &&
                (!clickableOnly || node.isClickable) &&
                (!editableOnly || node.isEditable) &&
                (!scrollableOnly || node.isScrollable)
            if (ok) {
                val id = nextId++
                refs[id] = node
                hits.add(entry(id, node, depth))
            }
            true
        }
        return linkedMapOf(
            "package" to (root.packageName?.toString().orEmpty()),
            "count" to hits.size,
            "matches" to hits
        )
    }

    // ═══════════════════════════════════════════════════════
    // 3. 动作
    // ═══════════════════════════════════════════════════════

    /** 按 id 点击；节点不可点则向上找可点祖先，再不行回退坐标手势。 */
    fun tapNode(id: Int): Map<String, Any> {
        val node = refs[id]
            ?: return linkedMapOf("ok" to false, "error" to "节点 id=$id 不存在：界面可能已刷新，请重新 device_screen")
        if (!node.refresh()) {
            return linkedMapOf("ok" to false, "error" to "节点已失效：界面发生变化，请重新 device_screen")
        }
        var target: AccessibilityNodeInfo? = node
        var hops = 0
        while (target != null && hops < 8) {
            if (target.isEnabled && (target.isClickable || target.isCheckable)) break
            target = target.parent
            hops++
        }
        val t = target
            ?: return linkedMapOf("ok" to false, "error" to "该节点及其祖先都不可点击")
        val rect = Rect().also { t.getBoundsInScreen(it) }
        val label = t.text?.toString()?.trim().orEmpty()
            .ifEmpty { t.contentDescription?.toString()?.trim().orEmpty() }
        if (t.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
            return linkedMapOf("ok" to true, "via" to "action", "label" to label, "hops" to hops)
        }
        val gestureOk = tapAt(rect.centerX().toFloat(), rect.centerY().toFloat())
        return linkedMapOf(
            "ok" to gestureOk, "via" to "gesture", "label" to label,
            "x" to rect.centerX(), "y" to rect.centerY()
        )
    }

    /** 查找并点击首个匹配项（含可点祖先回退）。 */
    fun tapText(text: String, exact: Boolean = false): Map<String, Any> {
        val found = find(text = text, exact = exact, limit = 10)
        @Suppress("UNCHECKED_CAST")
        val matches = (found["matches"] as? List<Map<String, Any>>).orEmpty()
        if (matches.isEmpty()) return linkedMapOf("ok" to false, "error" to "屏幕上没有「$text」")
        for (m in matches) {
            val id = (m["id"] as? Number)?.toInt() ?: continue
            val r = tapNode(id)
            if (r["ok"] == true) return r + mapOf("matchedText" to text)
        }
        return linkedMapOf("ok" to false, "error" to "找到「$text」但都点不动", "count" to matches.size)
    }

    /** 向当前焦点输入框写文字；没有焦点框时先按坐标点一下。 */
    fun typeText(text: String): Map<String, Any> {
        val root = service.rootInActiveWindow
            ?: return linkedMapOf("ok" to false, "error" to "读不到当前窗口")
        val focused = findFocusedEditable(root)
        if (focused == null) {
            return linkedMapOf("ok" to false, "error" to "没有获得焦点的输入框：请先 tap 输入框")
        }
        val args = android.os.Bundle()
        args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        val ok = focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        return linkedMapOf("ok" to ok, "chars" to text.length)
    }

    fun swipe(direction: String, durationMs: Long = 300): Map<String, Any> {
        val (w, h) = screenSize()
        val cx = w / 2f
        val cy = h / 2f
        val dx = w * 0.35f
        val dy = h * 0.35f
        val (x1, y1, x2, y2) = when (direction.lowercase()) {
            "up" -> listOf(cx, cy + dy, cx, cy - dy)
            "down" -> listOf(cx, cy - dy, cx, cy + dy)
            "left" -> listOf(cx + dx, cy, cx - dx, cy)
            "right" -> listOf(cx - dx, cy, cx + dx, cy)
            else -> return linkedMapOf("ok" to false, "error" to "direction 只能是 up/down/left/right")
        }
        val ok = swipeAt(x1, y1, x2, y2, durationMs)
        return linkedMapOf("ok" to ok, "direction" to direction)
    }

    fun scrollForward(): Boolean {
        var scrollable: AccessibilityNodeInfo? = null
        val root = service.rootInActiveWindow ?: return false
        walk(root, 0) { n, _ ->
            if (n.isScrollable && n.isVisibleToUser) {
                scrollable = n
                false
            } else true
        }
        val s = scrollable ?: return swipeAt(540f, 1600f, 540f, 700f, 320)
        return s.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
    }

    /** 滚动直到找到目标文字。 */
    fun scrollUntilFound(text: String, maxScrolls: Int = 6): Map<String, Any> {
        var attempt = 0
        while (attempt <= maxScrolls) {
            val found = find(text = text, limit = 5)
            @Suppress("UNCHECKED_CAST")
            val matches = (found["matches"] as? List<Map<String, Any>>).orEmpty()
            if (matches.isNotEmpty()) {
                return linkedMapOf("ok" to true, "scrolls" to attempt, "matches" to matches)
            }
            if (attempt == maxScrolls) break
            scrollForward()
            Thread.sleep(350)
            attempt++
        }
        return linkedMapOf("ok" to false, "scrolls" to attempt, "error" to "滚动 $maxScrolls 次仍未找到「$text」")
    }

    /** 等某个文字出现。 */
    fun waitForText(text: String, timeoutMs: Long = 5000): Map<String, Any> {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            val found = find(text = text, limit = 3)
            @Suppress("UNCHECKED_CAST")
            val matches = (found["matches"] as? List<Map<String, Any>>).orEmpty()
            if (matches.isNotEmpty()) {
                return linkedMapOf("ok" to true, "waitedMs" to (timeoutMs - (deadline - System.currentTimeMillis())), "matches" to matches)
            }
            Thread.sleep(200)
        }
        return linkedMapOf("ok" to false, "error" to "${timeoutMs}ms 内没等到「$text」")
    }

    /** 等界面稳定（连续两次 dump 的文本指纹一致）。 */
    fun waitForIdle(timeoutMs: Long = 4000): Map<String, Any> {
        val deadline = System.currentTimeMillis() + timeoutMs
        var previous = ""
        var stable = 0
        while (System.currentTimeMillis() < deadline) {
            val fp = fingerprint()
            if (fp == previous) {
                stable++
                if (stable >= 2) return linkedMapOf("ok" to true, "stable" to true)
            } else {
                stable = 0
                previous = fp
            }
            Thread.sleep(180)
        }
        return linkedMapOf("ok" to false, "stable" to false, "error" to "界面在 ${timeoutMs}ms 内一直变化")
    }

    // ═══════════════════════════════════════════════════════
    // 4. 环境感知
    // ═══════════════════════════════════════════════════════

    fun foreground(): Map<String, Any> {
        val root = service.rootInActiveWindow
        val pkg = root?.packageName?.toString().orEmpty().ifEmpty { SolvhenAccessibilityService.lastPackage }
        return linkedMapOf(
            "package" to pkg,
            "app" to appLabel(pkg),
            "window" to activeWindowTitle(),
            "lastEvent" to service.lastEventPackage,
            "accessibility" to true
        )
    }

    /** 关闭挡路的弹窗。allowPermissions=false 时只点「取消/关闭/跳过」类。 */
    fun dismiss(allowPermissions: Boolean = false, maxClicks: Int = 2): Map<String, Any> {
        val labels = if (allowPermissions) SAFE_DISMISS + PERMISSION_ACCEPT else SAFE_DISMISS
        val clicked = mutableListOf<String>()
        var rounds = 0
        while (rounds < maxClicks) {
            val root = service.rootInActiveWindow ?: break
            var hit = false
            for (label in labels) {
                walk(root, 0) { n, _ ->
                    if (hit) return@walk false
                    val t = n.text?.toString()?.trim().orEmpty()
                    val d = n.contentDescription?.toString()?.trim().orEmpty()
                    if (!(t.equals(label, true) || d.equals(label, true))) return@walk true
                    val target = if (n.isClickable) n else n.parent
                    if (target != null && target.isEnabled &&
                        target.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                    ) {
                        clicked.add(label)
                        hit = true
                        false
                    } else true
                }
                if (hit) break
            }
            if (!hit) break
            rounds++
            Thread.sleep(220)
        }
        return linkedMapOf("ok" to true, "clicked" to clicked, "count" to clicked.size)
    }

    // ═══════════════════════════════════════════════════════
    // 5. 原子序列：一次确认，多步执行
    // ═══════════════════════════════════════════════════════

    /**
     * steps 每项形如：
     *   {"action":"tap","id":12}
     *   {"action":"tapText","text":"发送"}
     *   {"action":"text","text":"你好"}
     *   {"action":"swipe","direction":"up"}
     *   {"action":"scrollFind","text":"设置"}
     *   {"action":"wait","text":"已发送","timeoutMs":4000}
     *   {"action":"idle"}
     *   {"action":"dismiss"}
     *   {"action":"back"} / {"action":"home"} / {"action":"recents"}
     *   {"action":"sleep","ms":500}
     * 可选 settleMs 控制步间隔；optional=true 表示失败也继续。
     */
    fun sequence(steps: List<Map<String, Any>>): Map<String, Any> {
        val log = mutableListOf<Map<String, Any>>()
        for ((index, step) in steps.withIndex()) {
            val action = (step["action"] as? String).orEmpty()
            val result = try {
                runStep(action, step)
            } catch (t: Throwable) {
                linkedMapOf("ok" to false, "error" to (t.message ?: t.javaClass.simpleName))
            }
            log.add(linkedMapOf("step" to index, "action" to action, "result" to result))
            val failed = result["ok"] == false
            if (failed && step["optional"] != true) {
                return linkedMapOf("ok" to false, "failedStep" to index, "log" to log)
            }
            val settle = (step["settleMs"] as? Number)?.toLong() ?: 220L
            if (settle > 0) Thread.sleep(settle)
        }
        return linkedMapOf("ok" to true, "steps" to steps.size, "log" to log)
    }

    private fun runStep(action: String, step: Map<String, Any>): Map<String, Any> = when (action) {
        "tap" -> {
            val id = (step["id"] as? Number)?.toInt()
            when {
                id != null -> tapNode(id)
                step["text"] is String -> tapText(step["text"] as String, step["exact"] == true)
                else -> linkedMapOf("ok" to false, "error" to "tap 需要 id 或 text")
            }
        }
        "tapText" -> tapText(step["text"] as? String ?: "", step["exact"] == true)
        "text" -> typeText(step["text"] as? String ?: "")
        "swipe" -> swipe(step["direction"] as? String ?: "up", (step["duration"] as? Number)?.toLong() ?: 300L)
        "scrollFind" -> scrollUntilFound(
            step["text"] as? String ?: "",
            (step["maxScrolls"] as? Number)?.toInt() ?: 6
        )
        "wait" -> waitForText(
            step["text"] as? String ?: "",
            (step["timeoutMs"] as? Number)?.toLong() ?: 4000L
        )
        "idle" -> waitForIdle((step["timeoutMs"] as? Number)?.toLong() ?: 3000L)
        "dismiss" -> dismiss(step["allowPermissions"] == true)
        "back" -> linkedMapOf("ok" to service.pressBack())
        "home" -> linkedMapOf("ok" to service.pressHome())
        "recents" -> linkedMapOf("ok" to service.pressRecents())
        "notifications" -> linkedMapOf("ok" to service.openNotifications())
        "sleep" -> {
            Thread.sleep((step["ms"] as? Number)?.toLong() ?: 500L)
            linkedMapOf("ok" to true)
        }
        else -> linkedMapOf("ok" to false, "error" to "未知动作：$action")
    }

    // ═══════════════════════════════════════════════════════
    // 内部工具
    // ═══════════════════════════════════════════════════════

    private fun walk(node: AccessibilityNodeInfo, depth: Int, visit: (AccessibilityNodeInfo, Int) -> Boolean) {
        if (depth > MAX_DEPTH) return
        if (!visit(node, depth)) return
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            walk(child, depth + 1, visit)
        }
    }

    private fun entry(id: Int, node: AccessibilityNodeInfo, depth: Int): Map<String, Any> {
        val rect = Rect().also { node.getBoundsInScreen(it) }
        return linkedMapOf(
            "id" to id,
            "class" to (node.className?.toString()?.substringAfterLast('.') ?: ""),
            "text" to (node.text?.toString()?.trim() ?: ""),
            "desc" to (node.contentDescription?.toString()?.trim() ?: ""),
            "viewId" to (node.viewIdResourceName?.substringAfterLast('/') ?: ""),
            "clickable" to node.isClickable,
            "longClickable" to node.isLongClickable,
            "editable" to node.isEditable,
            "scrollable" to node.isScrollable,
            "checkable" to node.isCheckable,
            "checked" to node.isChecked,
            "focused" to node.isFocused,
            "enabled" to node.isEnabled,
            "depth" to depth,
            "bounds" to linkedMapOf(
                "l" to rect.left, "t" to rect.top, "r" to rect.right, "b" to rect.bottom,
                "cx" to rect.centerX(), "cy" to rect.centerY()
            )
        )
    }

    private fun fingerprint(): String {
        val root = service.rootInActiveWindow ?: return ""
        val sb = StringBuilder()
        var count = 0
        walk(root, 0) { n, _ ->
            if (count < 120) {
                val t = n.text?.toString().orEmpty()
                if (t.isNotEmpty()) { sb.append(t.take(24)).append('|'); count++ }
            }
            count < 120
        }
        sb.append("@").append(root.packageName?.toString().orEmpty())
        return sb.toString()
    }

    private fun findFocusedEditable(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (node.isFocused && node.isEditable) return node
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findFocusedEditable(child)
            if (found != null) return found
        }
        return null
    }

    private fun tapAt(x: Float, y: Float): Boolean {
        var ok = false
        val latch = CountDownLatch(1)
        service.performClick(x, y) { result ->
            ok = result
            latch.countDown()
        }
        latch.await(2, TimeUnit.SECONDS)
        return ok
    }

    private fun swipeAt(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long): Boolean {
        var ok = false
        val latch = CountDownLatch(1)
        service.performSwipe(x1, y1, x2, y2, durationMs) { result ->
            ok = result
            latch.countDown()
        }
        latch.await(3, TimeUnit.SECONDS)
        return ok
    }

    private fun activeWindowTitle(): String = try {
        service.windows.firstOrNull { it.isActive }?.title?.toString().orEmpty()
    } catch (_: Throwable) {
        ""
    }

    private fun screenSize(): Pair<Float, Float> = try {
        val dm = service.resources.displayMetrics
        dm.widthPixels.toFloat() to dm.heightPixels.toFloat()
    } catch (_: Throwable) {
        1080f to 2340f
    }

    private fun appLabel(pkg: String): String = try {
        val pm = service.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Throwable) {
        ""
    }
}