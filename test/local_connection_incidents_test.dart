import 'dart:async';

import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/local_connection_incidents.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const profile = VpnProfile(
  id: 'fixture-profile-id',
  name: 'fixture-profile-name',
  kind: VpnProfileKind.vlessXhttp,
  originalInput: 'fixture-import-secret',
  server: 'fixture.invalid',
);

void main() {
  test('Hermes bearer validation rejects whitespace and header injection', () {
    expect(
      LocalConnectionIncidentsService.isValidHermesBearer('fixture-_./+~='),
      isTrue,
    );
    expect(
      LocalConnectionIncidentsService.isValidHermesBearer('a' * 512),
      isTrue,
    );
    for (final invalid in [
      '',
      ' fixture',
      'fixture ',
      'fixture\n',
      'fixture\r\nX-Test: injected',
      'fixture=bad',
      'fixture${'=' * 9}',
      'кириллица',
      'a' * 513,
    ]) {
      expect(
        LocalConnectionIncidentsService.isValidHermesBearer(invalid),
        isFalse,
      );
    }
  });

  test(
    'Hermes delivery state only accepts typed consent and token presence',
    () {
      expect(HermesDeliveryState.parse(null), isNull);
      expect(HermesDeliveryState.parse({'enabled': true}), isNull);
      expect(
        HermesDeliveryState.parse({'enabled': 'true', 'tokenConfigured': true}),
        isNull,
      );
      final state = HermesDeliveryState.parse({
        'enabled': true,
        'tokenConfigured': true,
        'authorizationBlocked': true,
      });
      expect(state?.enabled, isTrue);
      expect(state?.tokenConfigured, isTrue);
      expect(state?.authorizationBlocked, isTrue);
      expect(state?.routeReady, isFalse);
    },
  );

  test('confirmed connection is not a failure even if a later write fails', () {
    final attempt = LocalConnectionIncidentAttempt('epoch')
      ..observedStart(profile, 'wifi')
      ..observedStartError(PlatformException(code: 'START_VPN_ERROR'))
      ..observedStart(profile, 'wifi')
      ..observedSuccess()
      ..observedStartError(StateError('Could not persist preference'));
    expect(attempt.takeTerminal(current: true, consentEpoch: 'epoch'), isNull);
  });

  test('one terminal record contains only verified fixed categories', () {
    final attempt = LocalConnectionIncidentAttempt('epoch')
      ..observedStart(profile, 'cellular')
      ..observedStartError(TimeoutException('fixture-secret-details'));
    expect(attempt.takeTerminal(current: true, consentEpoch: 'epoch'), {
      'epoch': 'epoch',
      'protocol': 'xhttp',
      'network': 'cellular',
      'stage': 'vpn_start',
      'code': 'timeout',
    });
    expect(attempt.takeTerminal(current: true, consentEpoch: 'epoch'), isNull);
  });

  test(
    'cancellation, stale generation and revoked consent suppress recording',
    () {
      for (final error in ['START_CANCELLED', 'VPN_PERMISSION_DENIED']) {
        final attempt = LocalConnectionIncidentAttempt('old')
          ..observedStart(profile, 'wifi')
          ..observedStartError(PlatformException(code: error))
          ..nextCandidate()
          ..observedStart(profile, 'wifi');
        expect(
          attempt.takeTerminal(current: true, consentEpoch: 'old'),
          isNull,
        );
      }
      final superseded = LocalConnectionIncidentAttempt('old')
        ..observedStart(profile, 'wifi');
      expect(
        superseded.takeTerminal(current: false, consentEpoch: 'old'),
        isNull,
      );
      final revoked = LocalConnectionIncidentAttempt('old')
        ..observedStart(profile, 'wifi');
      expect(revoked.takeTerminal(current: true, consentEpoch: 'new'), isNull);
    },
  );

  test(
    'a stale Auto candidate or unknown error is not promoted to a cause',
    () {
      final attempt = LocalConnectionIncidentAttempt('epoch')
        ..observedStart(profile, 'cellular')
        ..observedStartError(PlatformException(code: 'START_VPN_ERROR'))
        ..nextCandidate();
      expect(
        attempt.takeTerminal(current: true, consentEpoch: 'epoch'),
        isNull,
      );
      final unknown = LocalConnectionIncidentAttempt('epoch')
        ..observedStart(profile, 'arbitrary-ssid')
        ..observedStartError(StateError('TLS failure: fixture.invalid'));
      expect(unknown.takeTerminal(current: true, consentEpoch: 'epoch'), {
        'epoch': 'epoch',
        'protocol': 'xhttp',
        'network': 'unknown',
        'stage': 'unknown',
        'code': 'unknown',
      });
    },
  );
}
