import java.io.FileInputStream
import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val hasReleaseSigning = keystorePropertiesFile.exists() &&
    listOf("keyAlias", "keyPassword", "storeFile", "storePassword")
        .all { keystoreProperties[it]?.toString()?.isNotBlank() == true }
// Flutter passes the same compile flags to Dart and to Gradle as Base64 tokens.
// Do not log build defines. Missing, malformed or conflicting flags fail closed.
val hermesPilotKeys = listOf("YURICH_LOCAL_INCIDENT_PILOT", "YURICH_HERMES_PILOT")
val hermesIncidentPilot = providers.gradleProperty("dart-defines")
    .map { encoded ->
        runCatching {
            val defines = encoded.split(',').map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
            hermesPilotKeys.all { key ->
                defines.filter { it.substringBefore('=') == key } == listOf("$key=true")
            }
        }.getOrDefault(false)
    }.orElse(false)
val hermesDeliveryPilot = providers.gradleProperty("dart-defines").map { encoded ->
    hermesIncidentPilot.get() && runCatching {
        encoded.split(',').map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
            .filter { it.substringBefore('=') == "YURICH_HERMES_DELIVERY_PILOT" } ==
            listOf("YURICH_HERMES_DELIVERY_PILOT=true")
    }.getOrDefault(false)
}.orElse(false)

val hermesReleaseKeepFile = if (hermesDeliveryPilot.get())
    "proguard-hermes-pilot.pro" else "proguard-hermes-disabled.pro"

android {
    namespace = "online.dnsai.ivanvpn"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "online.dnsai.ivanvpn"
        minSdk = maxOf(23, flutter.minSdkVersion)
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("boolean", "HERMES_INCIDENT_PILOT", "false")
        buildConfigField("boolean", "HERMES_DELIVERY_PILOT", "false")
        manifestPlaceholders["hermesDeliveryPilot"] = "false"
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    lint {
        // Flutter rewrites android/local.properties with Windows paths during
        // builds. That generated local file is not shipped in the APK.
        disable += "PropertyEscape"
    }

    buildFeatures {
        buildConfig = true
    }

    flavorDimensions += "distribution"
    productFlavors {
        create("github") {
            dimension = "distribution"
            buildConfigField("String", "DISTRIBUTION_CHANNEL", "\"github\"")
            buildConfigField("boolean", "HERMES_INCIDENT_PILOT", hermesIncidentPilot.get().toString())
            buildConfigField("boolean", "HERMES_DELIVERY_PILOT", hermesDeliveryPilot.get().toString())
            manifestPlaceholders["hermesDeliveryPilot"] = hermesDeliveryPilot.get().toString()
        }
        create("tv") {
            dimension = "distribution"
            buildConfigField("String", "DISTRIBUTION_CHANNEL", "\"tv\"")
        }
        create("play") {
            dimension = "distribution"
            // Keep Play builds above Flutter's per-ABI APK version-code offsets.
            versionCode = flutter.versionCode + 10000
            buildConfigField("String", "DISTRIBUTION_CHANNEL", "\"play\"")
        }
        create("soak") {
            dimension = "distribution"
            buildConfigField("String", "DISTRIBUTION_CHANNEL", "\"soak\"")
        }
    }

    signingConfigs {
        if (hasReleaseSigning) create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
        }
    }

    buildTypes {
        release {
            signingConfigs.findByName("release")?.let { signingConfig = it }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
                hermesReleaseKeepFile,
            )
        }
    }
}

androidComponents {
    onVariants(selector().withFlavor("distribution" to "tv")) { variant ->
        // Flutter's default build-type filter also permits x86_64 for ARM targets.
        variant.packaging.jniLibs.excludes.addAll(
            listOf("lib/x86/**", "lib/x86_64/**"),
        )
    }
}

// Keep JNI's CMake metadata local when multiple workspaces share the Pub cache.
val jniProject = project(":jni")
jniProject.plugins.withId("com.android.library") {
    jniProject.extensions.configure<com.android.build.api.dsl.LibraryExtension> {
        externalNativeBuild.cmake.buildStagingDirectory = rootProject.file(".cxx/jni")
    }
}

flutter {
    source = "../.."
}
