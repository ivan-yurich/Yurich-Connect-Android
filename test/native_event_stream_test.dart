import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_singbox_vpn/flutter_singbox_method_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const prefix = 'com.tecclub.flutter_singbox';

  Future<void> emit(String name, ByteData envelope) async {
    final delivered = Completer<void>();
    binding.defaultBinaryMessenger.handlePlatformMessage(
      '$prefix/${name}_events',
      envelope,
      (_) => delivered.complete(),
    );
    await delivered.future;
    await Future<void>.delayed(Duration.zero);
  }

  for (final name in ['status', 'traffic', 'log']) {
    for (final malformed in [false, true]) {
      test('$name forwards ${malformed ? 'malformed maps' : 'channel errors'} '
          'and keeps delivering events', () async {
        for (final channel in ['status', 'traffic', 'log']) {
          binding.defaultBinaryMessenger.setMockMethodCallHandler(
            MethodChannel('$prefix/${channel}_events'),
            (_) async => null,
          );
        }
        final platform = MethodChannelFlutterSingbox();
        final stream = switch (name) {
          'status' => platform.onStatusChanged,
          'traffic' => platform.onTrafficUpdate,
          _ => platform.onLogMessage,
        };
        final events = <Map<String, dynamic>>[];
        final errors = <Object>[];
        final subscription = stream.listen(events.add, onError: errors.add);
        addTearDown(subscription.cancel);
        await Future<void>.delayed(Duration.zero);
        await emit(
          name,
          malformed
              ? const StandardMethodCodec().encodeSuccessEnvelope({
                  1: 'bad key',
                })
              : const StandardMethodCodec().encodeErrorEnvelope(
                  code: 'delivery',
                ),
        );
        expect(errors, hasLength(1));
        expect(
          errors.single,
          malformed ? isA<TypeError>() : isA<PlatformException>(),
        );
        await emit(
          name,
          const StandardMethodCodec().encodeSuccessEnvelope({
            'status': 'Started',
          }),
        );
        expect(events, [
          {'status': 'Started'},
        ]);
      });
    }
  }
}
