# Flutter SingBox

A Flutter plugin for integrating [Sing-Box](https://sing-box.sagernet.org/) VPN functionality into your Flutter applications. This plugin provides a complete bridge to the native Sing-Box implementation on Android.

[![pub package](https://img.shields.io/pub/v/flutter_singbox_vpn.svg)](https://pub.dev/packages/flutter_singbox_vpn)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Features

- ✅ **VPN Connection Management** - Start, stop, and monitor VPN connections
- ✅ **Real-time Status Updates** - Stream-based status monitoring
- ✅ **Traffic Statistics** - Upload/download speeds, data usage, connection counts
- ✅ **Log Streaming** - Real-time logs from sing-box core
- ✅ **Per-App Tunneling** - Include/exclude specific apps from VPN
- ✅ **16KB Page Size Support** - Compatible with Android 15+ devices
- ✅ **JSON Configuration** - Full sing-box JSON configuration support

## Platform Support

| Platform | Support | Sing-Box Version |
|----------|---------|------------------|
| Android  | ✅      | 1.12.12          |
| iOS      | ❌ Not Supported | - |
| macOS    | ❌ Not Supported | - |
| Windows  | ❌ Not Supported | - |
| Linux    | ❌ Not Supported | - |

> **Need iOS, macOS, or Windows support?**  
> Contact us at [tecclubx.com](https://tecclubx.com) or email [info@tecclubx.com](mailto:info@tecclubx.com) for custom development.

## Requirements

- Flutter SDK: `>=3.3.0`
- Dart SDK: `>=3.9.2`
- Android: `minSdk 21`, `targetSdk 36`

## Installation

Add the plugin to your `pubspec.yaml`:

```yaml
dependencies:
  flutter_singbox_vpn: ^1.1.2
```

Then run:

```bash
flutter pub get
```

## Android Setup

### 1. Update `android/app/build.gradle.kts`

```kotlin
android {
    compileSdk = 36
    
    defaultConfig {
        minSdk = 21
        targetSdk = 36
    }
    
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}
```

### 2. Update `android/app/src/main/AndroidManifest.xml`

Add the required permissions:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <!-- Essential VPN permissions -->
    <uses-permission android:name="android.permission.INTERNET" />
    
    <!-- Foreground service permissions - Required for VPN to run in background -->
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE" />
    
    <!-- Network and connectivity -->
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    
    <!-- Notifications - Show VPN status -->
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    
    <!-- Boot receiver - Auto-start VPN if enabled -->
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
    
    <application
        android:label="Your App"
        android:extractNativeLibs="true"
        tools:targetApi="36">
        
        <!-- Your activities here -->
        
    </application>
</manifest>
```

### 3. Update `android/settings.gradle.kts`

Add JitPack repository for sing-box library:

```kotlin
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}
```

## Usage

### Initialize the Plugin

```dart
import 'package:flutter_singbox_vpn/flutter_singbox.dart';

final flutterSingbox = FlutterSingbox();
```

### Save Configuration

Provide a valid sing-box JSON configuration:

```dart
String config = '''
{
  "dns": {
    "servers": [
      {
        "address": "tls://8.8.8.8",
        "tag": "dns-remote"
      }
    ]
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30"],
      "auto_route": true,
      "strict_route": true
    }
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "proxy",
      "server": "your-server.com",
      "server_port": 443,
      "password": "your-password"
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
''';

await flutterSingbox.saveConfig(config);
```

### Start/Stop VPN

```dart
// Start VPN connection
bool started = await flutterSingbox.startVPN();

// Stop VPN connection
bool stopped = await flutterSingbox.stopVPN();

// Get current status
String status = await flutterSingbox.getVPNStatus();
// Returns: "Stopped", "Starting", "Started", or "Stopping"
```

### Listen to Status Changes

```dart
flutterSingbox.onStatusChanged.listen((statusMap) {
  String status = statusMap['status'];
  int statusCode = statusMap['statusCode'];
  
  print('VPN Status: $status (code: $statusCode)');
});
```

Status codes:
- `0` - Stopped
- `1` - Starting  
- `2` - Started
- `3` - Stopping

### Monitor Traffic Statistics

```dart
flutterSingbox.onTrafficUpdate.listen((stats) {
  // Raw values (in bytes)
  int uploadSpeed = stats['uplinkSpeed'];
  int downloadSpeed = stats['downlinkSpeed'];
  int uploadTotal = stats['uplinkTotal'];
  int downloadTotal = stats['downlinkTotal'];
  
  // Formatted strings
  String uploadSpeedStr = stats['formattedUplinkSpeed'];     // e.g., "1.24 KB/s"
  String downloadSpeedStr = stats['formattedDownlinkSpeed']; // e.g., "5.67 MB/s"
  String uploadTotalStr = stats['formattedUplinkTotal'];     // e.g., "125.4 MB"
  String downloadTotalStr = stats['formattedDownlinkTotal']; // e.g., "1.2 GB"
  
  // Connection counts
  int connectionsIn = stats['connectionsIn'];
  int connectionsOut = stats['connectionsOut'];
});
```

### Stream Logs

```dart
flutterSingbox.onLogMessage.listen((logEvent) {
  if (logEvent['type'] == 'log') {
    String message = logEvent['message'];
    print('Log: $message');
  }
});

// Get buffered logs
List<String> logs = await flutterSingbox.getLogs();

// Clear log buffer
await flutterSingbox.clearLogs();
```

### Per-App Tunneling

```dart
// Set mode: "off", "include", or "exclude"
await flutterSingbox.setPerAppProxyMode(ProxyMode.EXCLUDE);

// Set app list (package names)
await flutterSingbox.setPerAppProxyList([
  'com.whatsapp',
  'com.instagram.android',
]);

// Get current settings
String mode = await flutterSingbox.getPerAppProxyMode();
List<String> apps = await flutterSingbox.getPerAppProxyList();

// Get installed apps for selection UI
List<Map<String, dynamic>> installedApps = await flutterSingbox.getInstalledApps();
for (var app in installedApps) {
  print('${app['appName']} - ${app['packageName']}');
}
```

## Complete Example

```dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_singbox_vpn/flutter_singbox.dart';

void main() => runApp(MyApp());

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final FlutterSingbox _singbox = FlutterSingbox();
  String _status = 'Stopped';
  String _uploadSpeed = '0 B/s';
  String _downloadSpeed = '0 B/s';
  StreamSubscription? _statusSub;
  StreamSubscription? _trafficSub;

  @override
  void initState() {
    super.initState();
    _initVPN();
  }

  void _initVPN() {
    // Listen to status changes
    _statusSub = _singbox.onStatusChanged.listen((status) {
      setState(() => _status = status['status']);
    });

    // Listen to traffic updates
    _trafficSub = _singbox.onTrafficUpdate.listen((stats) {
      setState(() {
        _uploadSpeed = stats['formattedUplinkSpeed'];
        _downloadSpeed = stats['formattedDownlinkSpeed'];
      });
    });
  }

  Future<void> _toggleVPN() async {
    if (_status == VPNStatus.STOPPED) {
      await _singbox.saveConfig(yourConfigJson);
      await _singbox.startVPN();
    } else if (_status == VPNStatus.STARTED) {
      await _singbox.stopVPN();
    }
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _trafficSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: Text('SingBox VPN')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Status: $_status'),
              SizedBox(height: 16),
              Text('↑ $_uploadSpeed'),
              Text('↓ $_downloadSpeed'),
              SizedBox(height: 32),
              ElevatedButton(
                onPressed: _toggleVPN,
                child: Text(_status == VPNStatus.STOPPED ? 'Connect' : 'Disconnect'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

## API Reference

### FlutterSingbox Class

| Method | Description | Returns |
|--------|-------------|---------|
| `saveConfig(String config)` | Save sing-box JSON configuration | `Future<bool>` |
| `getConfig()` | Get current configuration | `Future<String>` |
| `startVPN()` | Start VPN connection | `Future<bool>` |
| `stopVPN()` | Stop VPN connection | `Future<bool>` |
| `getVPNStatus()` | Get current VPN status | `Future<String>` |
| `setPerAppProxyMode(String mode)` | Set per-app tunneling mode | `Future<bool>` |
| `getPerAppProxyMode()` | Get per-app tunneling mode | `Future<String>` |
| `setPerAppProxyList(List<String>? apps)` | Set apps for per-app tunneling | `Future<bool>` |
| `getPerAppProxyList()` | Get per-app tunneling app list | `Future<List<String>>` |
| `getInstalledApps()` | Get list of installed apps | `Future<List<Map>>` |
| `getLogs()` | Get buffered log messages | `Future<List<String>>` |
| `clearLogs()` | Clear log buffer | `Future<bool>` |

### Streams

| Stream | Description | Event Type |
|--------|-------------|------------|
| `onStatusChanged` | VPN status updates | `Map<String, dynamic>` |
| `onTrafficUpdate` | Traffic statistics | `Map<String, dynamic>` |
| `onLogMessage` | Log messages from sing-box | `Map<String, dynamic>` |

### Helper Classes

```dart
class VPNStatus {
  static const String STOPPED = "Stopped";
  static const String STARTING = "Starting";
  static const String STARTED = "Started";
  static const String STOPPING = "Stopping";
}

class ProxyMode {
  static const String OFF = "off";
  static const String INCLUDE = "include";
  static const String EXCLUDE = "exclude";
}
```

## Troubleshooting

### VPN Permission Not Granted

The plugin will automatically request VPN permission when `startVPN()` is called. Ensure your app handles the permission dialog properly.

### No Internet After Connecting

Check your sing-box configuration:
- Ensure DNS servers are properly configured
- Verify outbound proxy servers are reachable
- Check route rules are correct

### Build Errors

If you encounter build errors:

1. Clean and rebuild:
```bash
cd android && ./gradlew clean && cd ..
flutter clean
flutter pub get
flutter build apk
```

2. Ensure JitPack repository is added to `settings.gradle.kts`

### 16KB Page Size (Android 15+)

The plugin supports 16KB page size devices. Ensure your app's `build.gradle.kts` has:
```kotlin
android {
    compileSdk = 36
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}
```

## Changelog

### 1.1.1
- Fixed app launcher icon being overridden by plugin drawable
- Added VPN key icon for notification
- Fixed VPN status incorrectly showing "Started" when config has errors
- Improved error handling during VPN startup

### 1.1.0
- Added log streaming support
- Added 16KB page size support for Android 15+
- Improved VPN state management
- Fixed connection stability issues
- Updated to libbox 1.12.12

### 1.0.0
- Initial release

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Credits

- [Sing-Box](https://sing-box.sagernet.org/) - The universal proxy platform
- [TecClub](https://tecclubx.com) - Plugin development

## Contact

For support, custom development, or business inquiries:

- 🌐 Website: [tecclubx.com](https://tecclubx.com)
- 📧 Email: [info@tecclubx.com](mailto:info@tecclubx.com)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
