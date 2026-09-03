import 'package:aurum_vpn/src/services/fixed_size_batches.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('processes every item in bounded batches', () {
    final items = List<int>.generate(24, (index) => index);

    final batches = fixedSizeBatches(items, size: 4).toList();

    expect(batches, hasLength(6));
    expect(batches.every((batch) => batch.length == 4), isTrue);
    expect(batches.expand((batch) => batch), items);
  });

  test('keeps a partial final batch', () {
    expect(fixedSizeBatches(const [1, 2, 3, 4, 5], size: 3).toList(), const [
      [1, 2, 3],
      [4, 5],
    ]);
  });

  test('rejects an invalid batch size', () {
    expect(
      () => fixedSizeBatches(const [1], size: 0).toList(),
      throwsArgumentError,
    );
  });
}
