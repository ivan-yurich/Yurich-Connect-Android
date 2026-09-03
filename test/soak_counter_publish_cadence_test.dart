import 'package:aurum_vpn/src/services/soak_counter_publish_cadence.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('blocks parallel publishes while a send is in flight', () {
    final cadence = SoakCounterPublishCadence();
    final now = DateTime.utc(2026, 8, 11);

    expect(cadence.tryBegin(now), isNotNull);
    expect(cadence.tryBegin(now.add(const Duration(seconds: 1))), isNull);
  });

  test('failed send can retry without a 55 second blind spot', () {
    final cadence = SoakCounterPublishCadence();
    final now = DateTime.utc(2026, 8, 11);

    final attempt = cadence.tryBegin(now);
    expect(attempt, isNotNull);
    cadence.complete(
      attempt: attempt!,
      succeeded: false,
      at: now.add(const Duration(seconds: 3)),
    );

    expect(cadence.tryBegin(now.add(const Duration(seconds: 4))), isNotNull);
  });

  test('successful send starts the 55 second cadence window', () {
    final cadence = SoakCounterPublishCadence();
    final now = DateTime.utc(2026, 8, 11);

    final attempt = cadence.tryBegin(now);
    expect(attempt, isNotNull);
    cadence.complete(attempt: attempt!, succeeded: true, at: now);

    expect(cadence.tryBegin(now.add(const Duration(seconds: 54))), isNull);
    expect(cadence.tryBegin(now.add(const Duration(seconds: 55))), isNotNull);
  });

  test('reset invalidates an older in-flight completion', () {
    final cadence = SoakCounterPublishCadence();
    final now = DateTime.utc(2026, 8, 11);
    final oldAttempt = cadence.tryBegin(now)!;

    cadence.reset();
    final currentAttempt = cadence.tryBegin(now)!;
    cadence.complete(attempt: oldAttempt, succeeded: true, at: now);

    expect(cadence.tryBegin(now), isNull);
    cadence.complete(attempt: currentAttempt, succeeded: false, at: now);
    expect(cadence.tryBegin(now), isNotNull);
  });
}
