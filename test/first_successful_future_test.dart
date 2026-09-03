import 'dart:async';

import 'package:aurum_vpn/src/services/first_successful_future.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'returns on first success without waiting for a stalled candidate',
    () async {
      final stalled = Completer<bool>();

      final result = await firstSuccessfulFuture(<Future<bool>>[
        stalled.future,
        Future<bool>.value(true),
      ]).timeout(const Duration(seconds: 1));

      expect(result, isTrue);
    },
  );

  test('returns false only after every candidate fails', () async {
    final result = await firstSuccessfulFuture(<Future<bool>>[
      Future<bool>.value(false),
      Future<bool>.error(StateError('unavailable')),
    ]);

    expect(result, isFalse);
  });

  test('empty candidate list is unsuccessful', () async {
    expect(await firstSuccessfulFuture(const <Future<bool>>[]), isFalse);
  });
}
