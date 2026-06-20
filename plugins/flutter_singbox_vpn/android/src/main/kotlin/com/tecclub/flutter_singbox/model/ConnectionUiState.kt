package com.tecclub.flutter_singbox.model

data class ConnectionUiState(
    val status: ConnectionStatus,
    val profileName: String?,
    val protocolDisplayName: String?,
    val countryName: String?,
    val countryCode: String?,
    val pingMs: Long?,
    val uploadSpeed: String,
    val downloadSpeed: String,
    val totalTraffic: String,
    val sessionDuration: String?
) {
    companion object {
        fun disconnected(): ConnectionUiState {
            return ConnectionUiState(
                status = ConnectionStatus.Disconnected,
                profileName = null,
                protocolDisplayName = null,
                countryName = null,
                countryCode = null,
                pingMs = null,
                uploadSpeed = "0 B/s",
                downloadSpeed = "0 B/s",
                totalTraffic = "0 B",
                sessionDuration = null
            )
        }

        fun connecting(
            profileName: String? = null,
            protocolDisplayName: String? = null,
            countryName: String? = null,
            countryCode: String? = null,
            pingMs: Long? = null
        ): ConnectionUiState {
            return ConnectionUiState(
                status = ConnectionStatus.Connecting,
                profileName = profileName,
                protocolDisplayName = protocolDisplayName,
                countryName = countryName,
                countryCode = countryCode,
                pingMs = pingMs,
                uploadSpeed = "0 B/s",
                downloadSpeed = "0 B/s",
                totalTraffic = "0 B",
                sessionDuration = null
            )
        }

        fun connected(
            profileName: String? = null,
            protocolDisplayName: String? = null,
            countryName: String? = null,
            countryCode: String? = null,
            pingMs: Long? = null,
            uploadSpeed: String = "0 B/s",
            downloadSpeed: String = "0 B/s",
            totalTraffic: String = "0 B",
            sessionDuration: String? = null
        ): ConnectionUiState {
            return ConnectionUiState(
                status = ConnectionStatus.Connected,
                profileName = profileName,
                protocolDisplayName = protocolDisplayName,
                countryName = countryName,
                countryCode = countryCode,
                pingMs = pingMs,
                uploadSpeed = uploadSpeed,
                downloadSpeed = downloadSpeed,
                totalTraffic = totalTraffic,
                sessionDuration = sessionDuration
            )
        }

        fun fromMap(value: Map<*, *>?): ConnectionUiState {
            if (value == null) return disconnected()
            val status = ConnectionStatus.from(value["status"]?.toString())
            val ping = when (val raw = value["pingMs"]) {
                is Number -> raw.toLong()
                is String -> raw.toLongOrNull()
                else -> null
            }
            return ConnectionUiState(
                status = status,
                profileName = clean(value["profileName"]),
                protocolDisplayName = clean(value["protocolDisplayName"]),
                countryName = clean(value["countryName"]),
                countryCode = clean(value["countryCode"]),
                pingMs = ping,
                uploadSpeed = clean(value["uploadSpeed"]) ?: "0 B/s",
                downloadSpeed = clean(value["downloadSpeed"]) ?: "0 B/s",
                totalTraffic = clean(value["totalTraffic"]) ?: "0 B",
                sessionDuration = clean(value["sessionDuration"])
            )
        }

        private fun clean(value: Any?): String? {
            val text = value?.toString()?.trim()
            return if (text.isNullOrEmpty()) null else text
        }
    }
}
