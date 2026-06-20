package com.tecclub.flutter_singbox.bg

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import com.tecclub.flutter_singbox.R
import com.tecclub.flutter_singbox.config.SimpleConfigManager
import com.tecclub.flutter_singbox.constant.Action
import com.tecclub.flutter_singbox.database.Settings
import com.tecclub.flutter_singbox.model.ConnectionStatus
import com.tecclub.flutter_singbox.model.ConnectionUiState

class VpnNotificationHelper(private val context: Context) {
    companion object {
        const val CHANNEL_ID = "yurich_connect_vpn"
        const val NOTIFICATION_ID = 1
    }

    private val manager: NotificationManager
        get() = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "Yurich Connect",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Yurich Connect VPN foreground notification"
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        manager.createNotificationChannel(channel)
    }

    fun buildNotification(state: ConnectionUiState): Notification {
        createNotificationChannel()

        val title = SimpleConfigManager.getNotificationTitle()
        val protocol = state.protocolDisplayName ?: "—"
        val country = formatCountry(state)
        val profile = state.profileName ?: "—"
        val ping = state.pingMs?.let { "$it ms" } ?: "—"
        val session = state.sessionDuration ?: "—"

        val contentText = when (state.status) {
            ConnectionStatus.Connected ->
                "${state.status.displayName} • $protocol"
            ConnectionStatus.Connecting ->
                "${state.status.displayName} • $protocol"
            ConnectionStatus.Disconnected ->
                state.status.displayName
        }

        val summary = when (state.status) {
            ConnectionStatus.Connected ->
                "$country • ↑ ${state.uploadSpeed} • ↓ ${state.downloadSpeed} • Σ ${state.totalTraffic}"
            ConnectionStatus.Connecting -> country
            ConnectionStatus.Disconnected -> "Протокол: — • Страна: —"
        }

        val bigText = buildString {
            appendLine(title)
            appendLine("Статус: ${state.status.displayName}")
            appendLine("Протокол: $protocol")
            appendLine("Страна: $country")
            appendLine("Профиль: $profile")
            appendLine("Пинг: $ping")
            appendLine("Скорость: ↑ ${state.uploadSpeed} / ↓ ${state.downloadSpeed}")
            appendLine("Трафик: ${state.totalTraffic}")
            append("Сессия: $session")
        }
        val openIntent = openPendingIntent()

        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification_shield)
            .setContentTitle(title)
            .setContentText(contentText)
            .setSubText("VPN")
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .bigText(bigText)
                    .setSummaryText(summary)
            )
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setOnlyAlertOnce(true)
            .setOngoing(state.status != ConnectionStatus.Disconnected)
            .setSilent(true)
            .setShowWhen(false)
            .setLocalOnly(true)
            .apply {
                if (openIntent != null) {
                    setContentIntent(openIntent)
                    addAction(
                        R.drawable.ic_notification_shield,
                        "Открыть",
                        openIntent
                    )
                }
                when (state.status) {
                    ConnectionStatus.Disconnected -> addAction(
                        R.drawable.ic_vpn_key,
                        "Подключить",
                        startPendingIntent()
                    )
                    ConnectionStatus.Connecting -> addAction(
                        R.drawable.ic_vpn_key,
                        "Отключить",
                        broadcastPendingIntent(Action.SERVICE_CLOSE, 101)
                    )
                    ConnectionStatus.Connected -> {
                        addAction(
                            R.drawable.ic_vpn_key,
                            "Отключить",
                            broadcastPendingIntent(Action.SERVICE_CLOSE, 101)
                        )
                        addAction(
                            R.drawable.ic_vpn_key,
                            "Переподключить",
                            broadcastPendingIntent(Action.SERVICE_RESTART, 102)
                        )
                    }
                }
            }
            .build()
    }

    fun updateNotification(state: ConnectionUiState) {
        manager.notify(NOTIFICATION_ID, buildNotification(state))
    }

    private fun formatCountry(state: ConnectionUiState): String {
        val name = state.countryName?.takeIf { it != "—" }
        val code = state.countryCode?.takeIf { it != "—" }
        val flag = countryCodeToFlag(code)
        return listOfNotNull(name, flag).joinToString(" ").ifEmpty { "—" }
    }

    private fun countryCodeToFlag(countryCode: String?): String? {
        val normalized = countryCode
            ?.trim()
            ?.uppercase()
            ?.takeIf { it.length == 2 && it.all { char -> char in 'A'..'Z' } }
            ?: return null
        val first = Character.codePointAt(normalized, 0) - 'A'.code + 0x1F1E6
        val second = Character.codePointAt(normalized, 1) - 'A'.code + 0x1F1E6
        return String(Character.toChars(first)) + String(Character.toChars(second))
    }

    private fun openPendingIntent(): PendingIntent? {
        val intent = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            ?: return null
        return PendingIntent.getActivity(context, 100, intent, pendingFlags())
    }

    private fun startPendingIntent(): PendingIntent {
        val intent = Intent(context, Settings.serviceClass()).apply {
            action = BoxService.ACTION_START
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(context, 103, intent, pendingFlags())
        } else {
            PendingIntent.getService(context, 103, intent, pendingFlags())
        }
    }

    private fun broadcastPendingIntent(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(action).setPackage(context.packageName)
        return PendingIntent.getBroadcast(context, requestCode, intent, pendingFlags())
    }

    private fun pendingFlags(): Int {
        return PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
    }
}
