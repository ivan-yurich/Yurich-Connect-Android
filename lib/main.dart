import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/services/on_device_diagnostics.dart';

void main() => _launch(tvMode: false);

@pragma('vm:entry-point')
void tvMain() => _launch(tvMode: true);

void _launch({required bool tvMode}) {
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();

      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        Zone.current.handleUncaughtError(
          details.exception,
          details.stack ?? StackTrace.current,
        );
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        Zone.current.handleUncaughtError(error, stack);
        return true;
      };

      runApp(YurichConnectApp(tvMode: tvMode));
    },
    (error, stack) {
      unawaited(OnDeviceDiagnosticsService.recordError('uncaught'));
      debugPrint('Unhandled Yurich Connect error: $error\n$stack');
    },
  );
}
