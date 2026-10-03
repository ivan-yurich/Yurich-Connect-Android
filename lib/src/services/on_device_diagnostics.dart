import 'package:flutter/services.dart';

class DiagnosticRun {
  const DiagnosticRun({
    this.active = false,
    this.available = false,
    this.endsAt,
    this.events = 0,
    this.rotatedEvents = 0,
  });

  final bool active;
  final bool available;
  final DateTime? endsAt;
  final int events;
  final int rotatedEvents;

  factory DiagnosticRun.fromMap(Map<dynamic, dynamic> value) {
    final end = value['endsAtMs'];
    return DiagnosticRun(
      active: value['active'] == true,
      available: value['available'] == true,
      endsAt: end is int && end > 0
          ? DateTime.fromMillisecondsSinceEpoch(end)
          : null,
      events: value['events'] is int ? value['events'] as int : 0,
      rotatedEvents: value['rotatedEvents'] is int
          ? value['rotatedEvents'] as int
          : 0,
    );
  }
}

class OnDeviceDiagnosticsService {
  static const channel = MethodChannel('online.dnsai.ivanvpn/diagnostics');

  Future<DiagnosticRun> status() => _run('status');
  Future<DiagnosticRun> start() => _run('start');
  Future<DiagnosticRun> stop() => _run('stop');

  Future<DiagnosticRun> _run(String method) async {
    final value = await channel.invokeMapMethod<dynamic, dynamic>(method);
    return DiagnosticRun.fromMap(value ?? const {});
  }

  Future<bool> export() async =>
      await channel.invokeMethod<bool>('export') ?? false;

  static Future<void> recordError(String type) async {
    if (!const {'framework', 'uncaught', 'event_stream'}.contains(type)) return;
    try {
      await channel.invokeMethod<void>('recordError', {'type': type});
    } on Object {
      // Diagnostics are optional and must not recursively report their own errors.
    }
  }
}
