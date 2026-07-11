package com.tecclub.flutter_singbox.config

import android.content.Context
import android.util.Log
import com.tecclub.flutter_singbox.Application

object SimpleConfigManager {
    private const val TAG = "SimpleConfigManager"
    private const val PREF_NAME = "singbox_config"
    private const val KEY_CONFIG = "config_json"
    private const val KEY_AUTO_START = "auto_start"
    private const val KEY_STARTED_BY_USER = "started_by_user"
    private const val KEY_NOTIFICATION_TITLE = "notification_title"
    private const val KEY_NOTIFICATION_DESCRIPTION = "notification_description"
    private const val DEFAULT_CONFIG = "{}"
    private const val DEFAULT_NOTIFICATION_TITLE = "Yurich Connect"
    private const val DEFAULT_NOTIFICATION_DESCRIPTION = "VPN подключение активно"
    
    // Initialize the config manager with context
    fun init(context: Context) {
        // Any initialization can go here if needed
        Log.d(TAG, "SimpleConfigManager initialized")
    }
    
    // In-memory storage of the config for reliable access
    @Volatile
    private var cachedConfig: String = DEFAULT_CONFIG
    
    fun cacheConfig(config: String): Boolean {
        if (config.isBlank()) return false
        cachedConfig = config
        return true
    }

    fun saveConfig(config: String): Boolean {
        if (!cacheConfig(config)) return false
        return persistConfig(config)
    }

    @Synchronized
    fun persistConfig(config: String): Boolean {
        Log.e(TAG, "Persisting config, length: ${config.length}")
        if (config.isBlank()) return false

        return try {
            val prefs = Application.application.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            val encrypted = SecureConfigCipher.encrypt(config)
            if (!prefs.edit().putString(KEY_CONFIG, encrypted).commit()) {
                Log.e(TAG, "Config commit returned false")
                return false
            }
            Log.e(TAG, "Config persisted successfully")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to save config", e)
            false
        }
    }
    
    // Get current config JSON string
    fun getConfig(): String {
        Log.e(TAG, "Getting config")
        
        // If we have a cached config, return it
        if (cachedConfig != DEFAULT_CONFIG) {
            Log.e(TAG, "Returning cached config, length: ${cachedConfig.length}")
            return cachedConfig
        }
        
        // Otherwise load from preferences
        try {
            val prefs = Application.application.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            val stored = prefs.getString(KEY_CONFIG, DEFAULT_CONFIG) ?: DEFAULT_CONFIG
            val config = decodeStoredConfig(prefs, stored)
            cachedConfig = config
            
            Log.e(TAG, "Config loaded from preferences, length: ${config.length}")
            return config
        } catch (e: Exception) {
            Log.e(TAG, "Error getting config", e)
            return DEFAULT_CONFIG
        }
    }
    
    // Check if we have a valid config (not empty or default)
    fun hasValidConfig(): Boolean {
        val config = getConfig()
        return config.isNotEmpty() && config != DEFAULT_CONFIG
    }

    fun hasValidConfig(context: Context): Boolean {
        return try {
            val prefs = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            val stored = prefs.getString(KEY_CONFIG, DEFAULT_CONFIG) ?: DEFAULT_CONFIG
            val config = decodeStoredConfig(prefs, stored)
            config.isNotEmpty() && config != DEFAULT_CONFIG
        } catch (e: Exception) {
            Log.e(TAG, "Failed to check config with context", e)
            false
        }
    }

    private fun decodeStoredConfig(
        prefs: android.content.SharedPreferences,
        stored: String,
    ): String {
        if (stored.isEmpty() || stored == DEFAULT_CONFIG) {
            return DEFAULT_CONFIG
        }
        if (SecureConfigCipher.isEncrypted(stored)) {
            return SecureConfigCipher.decrypt(stored)
        }

        val encrypted = SecureConfigCipher.encrypt(stored)
        if (!prefs.edit().putString(KEY_CONFIG, encrypted).commit()) {
            error("Unable to migrate runtime config to encrypted storage")
        }
        Log.i(TAG, "Migrated runtime config to Android Keystore encryption")
        return stored
    }
    
    // Set auto-start setting
    fun setAutoStart(enabled: Boolean) {
        try {
            val prefs = Application.application.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            prefs.edit().putBoolean(KEY_AUTO_START, enabled).apply()
            Log.d(TAG, "Auto-start set to: $enabled")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to save auto-start setting", e)
        }
    }
    
    // Get auto-start setting
    fun getAutoStart(): Boolean {
        return try {
            val prefs = Application.application.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            prefs.getBoolean(KEY_AUTO_START, false)
        } catch (e: UninitializedPropertyAccessException) {
            Log.w(TAG, "Application not initialized, cannot get auto-start setting")
            false
        }
    }
    
    // Set notification title
    fun setNotificationTitle(title: String) {
        try {
            val prefs = Application.application.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            prefs.edit().putString(KEY_NOTIFICATION_TITLE, title).apply()
            Log.d(TAG, "Notification title set to: $title")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to save notification title", e)
        }
    }
    
    // Get notification title
    fun getNotificationTitle(): String {
        return try {
            val prefs = Application.application.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            prefs.getString(KEY_NOTIFICATION_TITLE, DEFAULT_NOTIFICATION_TITLE) ?: DEFAULT_NOTIFICATION_TITLE
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get notification title", e)
            DEFAULT_NOTIFICATION_TITLE
        }
    }
    
    // Set notification description
    fun setNotificationDescription(description: String) {
        try {
            val prefs = Application.application.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            prefs.edit().putString(KEY_NOTIFICATION_DESCRIPTION, description).apply()
            Log.d(TAG, "Notification description set to: $description")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to save notification description", e)
        }
    }
    
    // Get notification description
    fun getNotificationDescription(): String {
        return try {
            val prefs = Application.application.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            prefs.getString(KEY_NOTIFICATION_DESCRIPTION, DEFAULT_NOTIFICATION_DESCRIPTION) ?: DEFAULT_NOTIFICATION_DESCRIPTION
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get notification description", e)
            DEFAULT_NOTIFICATION_DESCRIPTION
        }
    }
    
    // Get auto-start setting with context (for use before Application is initialized)
    fun getAutoStart(context: Context): Boolean {
        return try {
            val prefs = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            prefs.getBoolean(KEY_AUTO_START, false)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get auto-start setting", e)
            false
        }
    }
    
    // Set started by user flag
    fun setStartedByUser(started: Boolean) {
        try {
            val prefs = Application.application.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            if (!prefs.edit().putBoolean(KEY_STARTED_BY_USER, started).commit()) {
                Log.w(TAG, "Started-by-user commit returned false")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to save started-by-user setting", e)
        }
    }
    
    // Get started by user flag
    fun getStartedByUser(): Boolean {
        val prefs = Application.application.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
        return prefs.getBoolean(KEY_STARTED_BY_USER, false)
    }

    fun getStartedByUser(context: Context): Boolean {
        return try {
            val prefs = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            prefs.getBoolean(KEY_STARTED_BY_USER, false)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get started-by-user setting with context", e)
            false
        }
    }
}
