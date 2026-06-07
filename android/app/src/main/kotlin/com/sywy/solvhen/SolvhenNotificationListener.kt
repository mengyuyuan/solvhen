package com.sywy.solvhen

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.app.Notification
import android.os.Bundle

/**
 * Solvhen 通知监听服务 — 读取微信/QQ等App的通知消息
 * 
 * 启用方法：设置 → 无障碍 → 已安装的服务 → Solvhen 通知监听 → 开启
 * 使用前需用户在系统设置中手动授权。
 */
class SolvhenNotificationListener : NotificationListenerService() {

    companion object {
        var instance: SolvhenNotificationListener? = null
            private set
        
        /** 最近收到的通知（最多保留100条） */
        private val recentNotifications = mutableListOf<Map<String, Any?>>()
        private const val MAX_NOTIFICATIONS = 100

        fun isEnabled(context: android.content.Context): Boolean {
            val enabledListeners = android.provider.Settings.Secure.getString(
                context.contentResolver,
                "enabled_notification_listeners"
            ) ?: return false
            return enabledListeners.contains(context.packageName)
        }

        /** 获取最近的通知列表，可按包名过滤 */
        fun getRecentNotifications(packageFilter: String = ""): List<Map<String, Any?>> {
            val list = if (packageFilter.isBlank()) {
                recentNotifications.toList()
            } else {
                recentNotifications.filter { 
                    val pkg = it["package"] as? String ?: ""
                    val app = it["app"] as? String ?: ""
                    pkg.contains(packageFilter, ignoreCase = true) ||
                    app.contains(packageFilter, ignoreCase = true)
                }
            }
            return list.takeLast(30)
        }

        /** 清空通知缓存 */
        fun clearNotifications() {
            recentNotifications.clear()
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        instance = null
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        super.onNotificationPosted(sbn)
        if (sbn == null) return
        
        val notification = sbn.notification
        val extras = notification.extras
        
        val title = extras.getString(Notification.EXTRA_TITLE) ?: ""
        val text = extras.getString(Notification.EXTRA_TEXT) ?: 
                   extras.getString(Notification.EXTRA_BIG_TEXT) ?: ""
        val subText = extras.getString(Notification.EXTRA_SUB_TEXT) ?: ""
        
        val body = if (text.isNotEmpty()) text else subText
        
        if (title.isNotEmpty() || body.isNotEmpty()) {
            val item = mapOf<String, Any?>(
                "package" to sbn.packageName,
                "app" to guessAppName(sbn.packageName),
                "title" to title,
                "body" to body,
                "time" to sbn.postTime,
                "id" to sbn.id,
                "tag" to sbn.tag,
            )
            synchronized(recentNotifications) {
                recentNotifications.add(item)
                if (recentNotifications.size > MAX_NOTIFICATIONS) {
                    recentNotifications.removeAt(0)
                }
            }
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        super.onNotificationRemoved(sbn)
    }

    private fun guessAppName(packageName: String): String {
        return when (packageName) {
            "com.tencent.mm" -> "微信"
            "com.tencent.mobileqq" -> "QQ"
            "com.tencent.wework" -> "企业微信"
            else -> packageName.substringAfterLast(".")
        }
    }
}
