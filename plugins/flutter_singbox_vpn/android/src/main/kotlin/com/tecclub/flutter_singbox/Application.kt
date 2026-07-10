package com.tecclub.flutter_singbox

import android.app.NotificationManager
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.os.PowerManager
import androidx.core.content.getSystemService
import com.tecclub.flutter_singbox.config.SimpleConfigManager
import go.Seq
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SetupOptions
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File

class Application {
    companion object {
        // Instance of the application context
        lateinit var application: Context
            private set
        @Volatile
        private var libboxInitialized = false
        @Volatile
        private var libboxInitializing = false
        @Volatile
        private var seqContextSet = false
        private val libboxLock = Any()
        private val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        
        // Quick access to common system services
        val powerManager: PowerManager by lazy { 
            application.getSystemService(Context.POWER_SERVICE) as PowerManager 
        }
        
        val connectivity by lazy { 
            application.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager 
        }
        
        val packageManager by lazy { 
            application.packageManager 
        }
        
        val notificationManager by lazy { 
            application.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager 
        }
        
        val wifiManager by lazy { 
            application.getSystemService(Context.WIFI_SERVICE) as WifiManager 
        }
        
        val clipboard by lazy { 
            application.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager 
        }
        
        // Version info for the app
        val versionName by lazy {
            try {
                application.packageManager.getPackageInfo(application.packageName, 0).versionName
            } catch (e: PackageManager.NameNotFoundException) {
                "com.tecclub.flutter_singbox"
            }
        }
        
        val versionCode: Long by lazy {
            try {
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                    application.packageManager.getPackageInfo(application.packageName, 0).longVersionCode
                } else {
                    @Suppress("DEPRECATION")
                    application.packageManager.getPackageInfo(application.packageName, 0).versionCode.toLong()
                }
            } catch (e: PackageManager.NameNotFoundException) {
                0L
            }
        }
        
        /**
         * Initialize the application with the given context
         * This is called from the FlutterSingboxPlugin when the plugin is attached to the engine
         */
        fun initialize(context: Context) {
            application = context.applicationContext
            
            // Initialize config manager
            SimpleConfigManager.init(application)
            
            var shouldInitializeLibbox = false
            synchronized(libboxLock) {
                if (!libboxInitialized && !libboxInitializing) {
                    libboxInitializing = true
                    shouldInitializeLibbox = true
                }
            }
            if (shouldInitializeLibbox) {
                applicationScope.launch {
                    try {
                        initializeLibbox(application)
                        synchronized(libboxLock) {
                            libboxInitialized = true
                            libboxInitializing = false
                        }
                    } catch (error: Exception) {
                        synchronized(libboxLock) {
                            libboxInitializing = false
                        }
                        android.util.Log.e("Application", "Failed to initialize libbox", error)
                    }
                }
            }
        }
        
        /**
         * Initialize the application if it hasn't been initialized yet
         * This is used by components that may run before the Flutter engine starts (e.g., BootReceiver)
         */
        fun initializeIfNeeded(context: Context) {
            try {
                // Check if already initialized
                application
            } catch (e: UninitializedPropertyAccessException) {
                // Not initialized, do it now
                android.util.Log.d("Application", "Initializing application from external component")
                initialize(context)
            }
        }

        /**
         * Ensure libbox is ready before a background service starts the core.
         * Service restarts can happen without a Flutter engine, so the async
         * initialization path may still be running when BoxService starts.
         */
        fun ensureLibboxInitialized(context: Context) {
            initializeIfNeeded(context)

            var shouldInitialize = false
            val deadline = System.currentTimeMillis() + 5000
            while (true) {
                var waitForInitializer = false
                synchronized(libboxLock) {
                    if (libboxInitialized) {
                        return
                    }
                    if (!libboxInitializing) {
                        libboxInitializing = true
                        shouldInitialize = true
                    } else {
                        waitForInitializer = true
                    }
                }

                if (shouldInitialize) {
                    break
                }

                if (System.currentTimeMillis() >= deadline) {
                    android.util.Log.w(
                        "Application",
                        "Timed out waiting for libbox initialization; continuing service start"
                    )
                    return
                }
                if (waitForInitializer) {
                    Thread.sleep(50)
                }
            }

            if (shouldInitialize) {
                try {
                    initializeLibbox(application)
                    synchronized(libboxLock) {
                        libboxInitialized = true
                        libboxInitializing = false
                    }
                } catch (error: Exception) {
                    synchronized(libboxLock) {
                        libboxInitializing = false
                    }
                    android.util.Log.e("Application", "Failed to initialize libbox for service", error)
                    throw error
                }
            }
        }
        
        /**
         * Check if the application has been initialized
         */
        fun isInitialized(): Boolean {
            return try {
                application
                true
            } catch (e: UninitializedPropertyAccessException) {
                false
            }
        }
        
        /**
         * Initialize the libbox library with the application's directories
         */
        private fun initializeLibbox(context: Context) {
            ensureSeqContext(context)

            val baseDir = context.filesDir
            baseDir.mkdirs()
            val workingDir = context.getExternalFilesDir(null) ?: return
            workingDir.mkdirs()
            val tempDir = context.cacheDir
            tempDir.mkdirs()
            
            // Match official app: fixAndroidStack for Android N-N_MR1 and P+
            // See: https://github.com/golang/go/issues/68760
            val fixAndroidStack = android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N && 
                    android.os.Build.VERSION.SDK_INT <= android.os.Build.VERSION_CODES.N_MR1 ||
                    android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P
            
            val setupOptions = SetupOptions()
            setupOptions.basePath = baseDir.path
            setupOptions.workingPath = workingDir.path
            setupOptions.tempPath = tempDir.path
            setupOptions.fixAndroidStack = fixAndroidStack
            
            android.util.Log.d("Application", "Initializing libbox with fixAndroidStack=$fixAndroidStack")
            
            Libbox.setup(setupOptions)
            Libbox.redirectStderr(File(workingDir, "stderr.log").path)
        }

        private fun ensureSeqContext(context: Context) {
            if (seqContextSet) {
                return
            }
            synchronized(libboxLock) {
                if (!seqContextSet) {
                    Seq.setContext(context.applicationContext)
                    seqContextSet = true
                }
            }
        }
    }
}
