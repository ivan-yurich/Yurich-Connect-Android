import 'package:aurum_vpn/src/services/app_release_version.dart';
import 'package:aurum_vpn/src/services/app_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AppReleaseVersion version(String value) => AppReleaseVersion.tryParse(value)!;

  test('normalizes a stable tag and optional Android build metadata', () {
    expect(version(' v1.0.127+43139 ').value, '1.0.127');
    expect(version('1.0.127').isTesting, isFalse);
  });

  test('preserves the full testing identity', () {
    final parsed = version('v1.0.128-test.20261008.10');
    expect(parsed.value, '1.0.128-test.20261008.10');
    expect(parsed.isTesting, isTrue);
  });

  test('orders testing iterations numerically, not lexically', () {
    expect(
      version(
        '1.0.128-test.20261008.10',
      ).compareTo(version('1.0.128-test.20261008.9')),
      greaterThan(0),
    );
  });

  test('orders testing dates before iteration numbers', () {
    expect(
      version(
        '1.0.128-test.20261008.1',
      ).compareTo(version('1.0.128-test.20261007.99')),
      greaterThan(0),
    );
  });

  test('a stable version supersedes its testing candidates', () {
    expect(
      version('1.0.128').compareTo(version('1.0.128-test.20261008.10')),
      greaterThan(0),
    );
  });

  test('compares base versions before testing status', () {
    expect(
      version('1.0.129-test.20261008.1').compareTo(version('1.0.128')),
      greaterThan(0),
    );
    expect(version('1.0.128').compareTo(version('1.0.99')), greaterThan(0));
  });

  test('an identical testing build is not newer', () {
    expect(
      version(
        'v1.0.128-test.20261008.10',
      ).compareTo(version('1.0.128-test.20261008.10')),
      0,
    );
  });

  test('rejects other platforms, invalid dates and malformed versions', () {
    for (final value in [
      '1.0.128-tv.20261003.1',
      '1.0.128-beta.1',
      'release 1.0.128',
      '1.0.128-test.20260230.1',
      '1.0.128-test.20261301.1',
      '1.0.128-test.20261008.0',
      '1.0.128-test.20261008.999999999999999999999999',
      '1.0',
      '../1.0.128',
      '1.0.128-test.20261008.10/other',
    ]) {
      expect(AppReleaseVersion.tryParse(value), isNull, reason: value);
    }
  });

  test('only recognized testing builds opt into testing updates', () {
    expect(AppUpdateService.usesTestingChannel('1.0.128'), isFalse);
    expect(
      AppUpdateService.usesTestingChannel('1.0.128-tv.20261003.1'),
      isFalse,
    );
    expect(
      AppUpdateService.usesTestingChannel('1.0.128-test.20261008.10'),
      isTrue,
    );
    expect(
      AppUpdateService.manualDownloadUri('1.0.128-test.20261008.10').path,
      endsWith('/releases'),
    );
  });

  bool due({
    Duration elapsed = Duration.zero,
    Duration? previous,
    bool inFlight = false,
    bool foreground = true,
  }) => AppUpdateNoticePolicy.shouldCheck(
    elapsed: elapsed,
    lastAttempt: previous,
    inFlight: inFlight,
    foreground: foreground,
  );

  test('automatic update check is eligible on the first foreground visit', () {
    expect(due(), isTrue);
  });

  test('automatic update checks do not overlap or start in background', () {
    expect(due(inFlight: true), isFalse);
    expect(due(foreground: false), isFalse);
  });

  test('resume checks are rate limited to six monotonic hours', () {
    expect(
      due(elapsed: const Duration(hours: 5), previous: Duration.zero),
      isFalse,
    );
    expect(
      due(elapsed: const Duration(hours: 6), previous: Duration.zero),
      isTrue,
    );
    expect(
      due(elapsed: const Duration(hours: 7), previous: Duration.zero),
      isTrue,
    );
  });

  test('a non-monotonic elapsed sample does not bypass the limiter', () {
    expect(due(previous: const Duration(hours: 1)), isFalse);
  });
}
