import 'dart:io';

import 'package:aurum_vpn/src/services/kill_switch_http_policy.dart';
import 'package:aurum_vpn/src/services/kill_switch_service.dart';
import 'package:aurum_vpn/src/services/sing_box_config_builder.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const open = KillSwitchState(known: true);
  const restricted = KillSwitchState(
    known: true,
    alwaysOn: true,
    lockdown: true,
  );
  const proxy = 'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}';

  test('restriction closes every registered direct client before reuse', () {
    final routes = KillSwitchHttpRoutes();
    final first = _FixtureHttpClient();
    final second = _FixtureHttpClient();
    routes.apply(first, open);
    routes.apply(second, open);
    expect(first.route(), isNull);
    expect(second.route(), isNull);

    expect(
      () => routes.apply(first, restricted),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Network policy changed; retry using a new HTTP client',
        ),
      ),
    );

    for (final client in [first, second]) {
      expect(client.closes, [true]);
      expect(routes.isRevoked(client), isTrue);
      expect(client.route(), isNull);
    }
    routes.cancelDirectRequests();
    expect(first.closes, [true]);
    expect(second.closes, [true]);

    routes.forget(first);
    expect(
      () => routes.apply(first, open),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'HTTP client revoked by network policy',
        ),
      ),
    );
    expect(
      () => routes.apply(first, open, alwaysProxy: true),
      throwsStateError,
    );
    expect(routes.isRevoked(first), isTrue);
    expect(first.route(), isNull);
  });

  test('a fresh client under protection gets a loopback-only route', () {
    final routes = KillSwitchHttpRoutes();
    for (final state in [
      const KillSwitchState(),
      const KillSwitchState(requested: true, supported: false),
      const KillSwitchState(known: true, vpnActive: true),
      restricted,
    ]) {
      final client = _FixtureHttpClient();
      routes.apply(client, state);
      expect(client.route(), proxy);
      expect(routes.isRevoked(client), isFalse);
      expect(client.closes, isEmpty);
    }
  });

  test('only a policy-owned proxy is cleared after protection is off', () {
    final routes = KillSwitchHttpRoutes();
    final policyClient = _FixtureHttpClient();
    final manualClient = _FixtureHttpClient()
      ..findProxy = (_) => 'PROXY fixture.invalid:8080';
    routes.apply(policyClient, restricted);
    routes.apply(policyClient, const KillSwitchState());
    expect(policyClient.route(), proxy);

    routes.apply(policyClient, open);
    routes.apply(manualClient, open);
    expect(policyClient.route(), isNull);
    expect(manualClient.route(), 'PROXY fixture.invalid:8080');

    routes.cancelDirectRequests();
    expect(policyClient.closes, [true]);
    expect(manualClient.closes, [true]);
  });

  test(
    'explicit loopback routing sticks without revoking other clear clients',
    () {
      final routes = KillSwitchHttpRoutes();
      final stock = _FixtureHttpClient();
      final explicit = _FixtureHttpClient();
      routes.apply(stock, open);
      routes.apply(explicit, open);
      routes.apply(explicit, open, alwaysProxy: true);
      expect(explicit.route(), proxy);
      expect(stock.closes, isEmpty);
      expect(routes.isRevoked(stock), isFalse);

      routes.cancelDirectRequests();
      expect(stock.closes, [true]);
      expect(explicit.closes, isEmpty);
      expect(routes.isRevoked(explicit), isFalse);
      routes.apply(explicit, open);
      expect(explicit.route(), proxy);
    },
  );

  test('forget unregisters a released client and registries stay isolated', () {
    final routes = KillSwitchHttpRoutes();
    final other = KillSwitchHttpRoutes();
    final released = _FixtureHttpClient();
    final live = _FixtureHttpClient();
    routes.apply(released, open);
    routes.apply(live, open);
    routes.forget(released);

    other.cancelDirectRequests();
    expect(live.closes, isEmpty);
    routes.cancelDirectRequests();
    expect(live.closes, [true]);
    expect(routes.isRevoked(live), isTrue);
    expect(other.isRevoked(live), isFalse);
    expect(released.closes, isEmpty);
    expect(routes.isRevoked(released), isFalse);
  });

  test(
    'endpoint diagnostics honor stored intent and fail closed on Android uncertainty',
    () {
      for (final state in [
        const KillSwitchState(),
        const KillSwitchState(requested: true, supported: false),
        const KillSwitchState(known: true, requested: true),
        const KillSwitchState(known: true, alwaysOn: true),
        const KillSwitchState(known: true, lockdown: true),
        restricted,
      ]) {
        expect(KillSwitchHttpRoutes.allowsEndpointDiagnostics(state), isFalse);
      }
      expect(KillSwitchHttpRoutes.allowsEndpointDiagnostics(open), isTrue);
      expect(
        KillSwitchHttpRoutes.allowsEndpointDiagnostics(
          const KillSwitchState(supported: false),
        ),
        isTrue,
      );
    },
  );

  test('desktop facade leaves the caller proxy intact', () async {
    final client = _FixtureHttpClient()
      ..findProxy = (_) => 'PROXY fixture.invalid:8080';
    await KillSwitchHttpPolicy.protect(client, alwaysProxy: true);
    expect(client.route(), 'PROXY fixture.invalid:8080');
    expect(client.closes, isEmpty);
    expect(await KillSwitchHttpPolicy.allowEndpointDiagnostics(), isTrue);
  }, skip: Platform.isAndroid);

  group('system snapshot routing', () {
    const channel = MethodChannel('com.tecclub.flutter_singbox/methods');
    const stateQuery = 'getKillSwitchState';
    const unrestricted = {'supported': true, 'known': true};
    const locked = {
      'supported': true,
      'known': true,
      'alwaysOn': true,
      'lockdown': true,
    };
    final messenger =
        TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
    final calls = <String>[];
    late TargetPlatform? previousPlatform;

    void reply(Object? Function() snapshot) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        expect(call.method, stateQuery);
        expect(call.arguments, isNull);
        return snapshot();
      });
    }

    setUp(() {
      previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      calls.clear();
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = previousPlatform;
    });

    for (final (label, snapshot, nativeError) in [
      ('missing snapshot', null, false),
      ('unknown system state', {'supported': true, 'known': false}, false),
      ('confirmed lockdown', locked, false),
      (
        'requested on unsupported OS',
        {'supported': false, 'requested': true},
        false,
      ),
      ('native error', null, true),
    ]) {
      test('fails closed with only the loopback proxy on $label', () async {
        reply(() {
          if (nativeError) throw PlatformException(code: 'fixture-unavailable');
          return snapshot;
        });
        final routes = KillSwitchHttpRoutes();
        final client = _FixtureHttpClient();
        await routes.protectFromSystem(client);
        expect(client.route(), proxy);
        expect(client.closes, isEmpty);
        expect(await routes.allowEndpointDiagnosticsFromSystem(), isFalse);
        expect(calls, [stateQuery, stateQuery]);
      });
    }

    test('reads changed state and revokes previously direct clients', () async {
      var snapshot = unrestricted;
      reply(() => snapshot);
      final routes = KillSwitchHttpRoutes();
      final direct = _FixtureHttpClient();
      await routes.protectFromSystem(direct);
      expect(direct.route(), isNull);
      expect(await routes.allowEndpointDiagnosticsFromSystem(), isTrue);

      snapshot = locked;
      final fresh = _FixtureHttpClient();
      await routes.protectFromSystem(fresh);
      expect(fresh.route(), proxy);
      expect(direct.closes, [true]);
      expect(routes.isRevoked(direct), isTrue);

      snapshot = unrestricted;
      await expectLater(routes.protectFromSystem(direct), throwsStateError);
      expect(direct.closes, [true]);
      expect(routes.isRevoked(direct), isTrue);
      expect(calls, List.filled(4, stateQuery));
    });

    test(
      'explicit tunnel probe stays proxied in a confirmed open state',
      () async {
        reply(() => unrestricted);
        final routes = KillSwitchHttpRoutes();
        final client = _FixtureHttpClient();
        await routes.protectFromSystem(client, alwaysProxy: true);
        expect(client.route(), proxy);
        routes.cancelDirectRequests();
        expect(client.closes, isEmpty);
        expect(calls, [stateQuery]);
      },
    );

    test(
      'desktop facade ignores the Flutter platform override',
      () async {
        reply(() => locked);
        final client = _FixtureHttpClient()
          ..findProxy = (_) => 'PROXY fixture.invalid:8080';
        await KillSwitchHttpPolicy.protect(client, alwaysProxy: true);
        expect(client.route(), 'PROXY fixture.invalid:8080');
        expect(client.closes, isEmpty);
        expect(await KillSwitchHttpPolicy.allowEndpointDiagnostics(), isTrue);
        expect(calls, isEmpty);
      },
      skip: Platform.isAndroid,
    );
  });
}

final class _FixtureHttpClient extends Fake implements HttpClient {
  @override
  String Function(Uri)? findProxy;

  final closes = <bool>[];

  String? route() => findProxy?.call(Uri.parse('https://fixture.invalid'));

  @override
  void close({bool force = false}) => closes.add(force);
}
