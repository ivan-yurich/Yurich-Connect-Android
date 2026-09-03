import 'package:aurum_vpn/src/services/preferred_first.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('moves the last successful item first', () {
    final ordered = preferredFirst<String>(
      const <String>['http-connect', 'native-naive'],
      preferredKey: 'native-naive',
      keyOf: (item) => item,
    );

    expect(ordered, const <String>['native-naive', 'http-connect']);
  });

  test('keeps default order for unknown or stale preference', () {
    final ordered = preferredFirst<String>(
      const <String>['http-connect', 'native-naive'],
      preferredKey: 'removed-plan',
      keyOf: (item) => item,
    );

    expect(ordered, const <String>['http-connect', 'native-naive']);
  });

  test('keeps relative order of non-preferred items', () {
    final ordered = preferredFirst<String>(
      const <String>['first', 'preferred', 'third'],
      preferredKey: 'preferred',
      keyOf: (item) => item,
    );

    expect(ordered, const <String>['preferred', 'first', 'third']);
  });
}
