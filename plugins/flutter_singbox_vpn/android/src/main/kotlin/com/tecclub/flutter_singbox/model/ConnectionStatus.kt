package com.tecclub.flutter_singbox.model

enum class ConnectionStatus(val displayName: String) {
    Connected("Подключено"),
    Disconnected("Отключено"),
    Connecting("Подключение...");

    companion object {
        fun from(value: String?): ConnectionStatus {
            return when (value?.trim()?.lowercase()) {
                "connected", "started" -> Connected
                "connecting", "starting" -> Connecting
                else -> Disconnected
            }
        }
    }
}
