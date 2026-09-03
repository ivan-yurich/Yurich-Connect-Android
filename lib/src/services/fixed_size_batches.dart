Iterable<List<T>> fixedSizeBatches<T>(
  Iterable<T> items, {
  required int size,
}) sync* {
  if (size <= 0) {
    throw ArgumentError.value(size, 'size', 'must be greater than zero');
  }

  final batch = <T>[];
  for (final item in items) {
    batch.add(item);
    if (batch.length == size) {
      yield List<T>.unmodifiable(batch);
      batch.clear();
    }
  }
  if (batch.isNotEmpty) {
    yield List<T>.unmodifiable(batch);
  }
}
