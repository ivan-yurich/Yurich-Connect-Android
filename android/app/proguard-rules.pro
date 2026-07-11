# Flutter registers plugins and MethodChannel entry points indirectly.
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }
-keep class online.dnsai.ivanvpn.MainActivity { *; }

# libbox and its Go/JNI bridge rely on stable native and reflected names.
-keep class com.tecclub.flutter_singbox.** { *; }
-keep class io.nekohasekai.libbox.** { *; }
-keep class go.** { *; }
-keepclasseswithmembernames class * {
    native <methods>;
}
