import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aurum_vpn/src/services/kill_switch_service.dart';
import 'package:aurum_vpn/src/services/kill_switch_http_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.tecclub.flutter_singbox/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('unknown or incomplete snapshots never confirm protection', () {
    for (final value in [
      <String, dynamic>{},
      {
        'supported': true,
        'lockdown': true,
        'alwaysOn': true,
        'strictRuntime': true,
      },
      {'supported': true, 'known': true, 'alwaysOn': true},
      {'supported': true, 'known': true, 'alwaysOn': true, 'lockdown': true},
      {
        'supported': true,
        'known': true,
        'lockdown': true,
        'strictRuntime': true,
      },
    ]) {
      expect(KillSwitchState.fromMap(value).fullyConfigured, isFalse);
    }
  });

  test('confirmed lockdown without strict TUN is a distinct pending state', () {
    const state = KillSwitchState(known: true, alwaysOn: true, lockdown: true);
    expect(state.systemEnforced, isTrue);
    expect(state.fullyConfigured, isFalse);
  });

  test('strict intent alone is never proof of Android protection', () {
    final state = KillSwitchState.fromMap({'requested': true});
    expect(state.requested, isTrue);
    expect(state.supported, isTrue);
    expect(state.systemEnforced, isFalse);
    expect(state.fullyConfigured, isFalse);
    expect(KillSwitchHttpPolicy.requiresProxy(state), isTrue);
  });

  test('strict intent keeps control requests proxied across TUN-less gaps', () {
    for (final supported in [true, false]) {
      expect(
        KillSwitchHttpPolicy.requiresProxy(
          KillSwitchState(supported: supported, known: true, requested: true),
        ),
        isTrue,
      );
    }
  });

  test(
    'read waits for an in-flight intent write and discards older replies',
    () async {
      final oldRead = Completer<Map<String, dynamic>>();
      final write = Completer<bool>();
      var reads = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'setKillSwitchRequested') {
          expect(call.arguments, {'enabled': true});
          return write.future;
        }
        reads++;
        return reads == 1
            ? oldRead.future
            : {'supported': true, 'requested': true};
      });
      const service = KillSwitchService();
      final before = service.read();
      await Future<void>.delayed(Duration.zero);
      final saving = service.setRequested(true);
      final during = service.read();
      oldRead.complete({'supported': true, 'known': true, 'requested': false});
      await Future<void>.delayed(Duration.zero);
      expect(reads, 1);
      write.complete(true);
      await saving;
      expect((await before).requested, isTrue);
      expect((await during).requested, isTrue);
    },
  );

  test('a rejected intent change is surfaced, never cached as saved', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setKillSwitchRequested') return false;
      return {'supported': true, 'requested': true};
    });
    const service = KillSwitchService();
    await expectLater(service.setRequested(false), throwsStateError);
    expect((await service.read()).requested, isTrue);
  });

  test('VPN owner HTTP fails closed for unknown state or enabled lockdown', () {
    expect(KillSwitchHttpPolicy.requiresProxy(const KillSwitchState()), isTrue);
    expect(
      KillSwitchHttpPolicy.requiresProxy(
        const KillSwitchState(known: true, lockdown: true),
      ),
      isTrue,
    );
    expect(
      KillSwitchHttpPolicy.requiresProxy(const KillSwitchState(known: true)),
      isFalse,
    );
    expect(
      KillSwitchHttpPolicy.requiresProxy(
        const KillSwitchState(supported: false),
      ),
      isFalse,
    );
  });

  test('only live complete native snapshot confirms strict mode', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getKillSwitchState');
      return {
        'supported': true,
        'known': true,
        'runtimeKnown': true,
        'vpnActive': true,
        'alwaysOn': true,
        'lockdown': true,
        'strictRuntime': true,
      };
    });
    expect((await const KillSwitchService().read()).fullyConfigured, isTrue);
  });

  test(
    'native failure is unknown and never a cached enabled preference',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(code: 'dead-binder'),
      );
      final state = await const KillSwitchService().read();
      expect(state.known, isFalse);
      expect(state.fullyConfigured, isFalse);
    },
  );

  test(
    'concurrent consumers share one live query, not a persisted cached state',
    () async {
      var calls = 0;
      final gate = Completer<Map<String, dynamic>>();
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return gate.future;
      });
      final reads = List.generate(5, (_) => const KillSwitchService().read());
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      gate.complete({
        'supported': true,
        'known': true,
        'runtimeKnown': true,
        'alwaysOn': true,
        'lockdown': true,
        'strictRuntime': true,
        'vpnActive': true,
      });
      expect(
        (await Future.wait(reads)).every((state) => state.fullyConfigured),
        isTrue,
      );
      await const KillSwitchService().read();
      expect(calls, 2);
    },
  );

  test(
    'unknown runtime never confirms protection or masquerades as a non-strict TUN',
    () {
      const state = KillSwitchState(
        known: true,
        alwaysOn: true,
        lockdown: true,
        strictRuntime: true,
        vpnActive: true,
      );
      expect(state.runtimeKnown, isFalse);
      expect(state.systemEnforced, isTrue);
      expect(state.fullyConfigured, isFalse);
    },
  );
}
