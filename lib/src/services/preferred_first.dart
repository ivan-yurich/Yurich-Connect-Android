/// Returns [items] with the preferred key first while preserving the relative
/// order of every other item.
List<T> preferredFirst<T>(
  Iterable<T> items, {
  required Object? preferredKey,
  required Object Function(T item) keyOf,
}) {
  final ordered = items.toList(growable: false);
  if (preferredKey == null) {
    return ordered;
  }
  final preferredIndex = ordered.indexWhere(
    (item) => keyOf(item) == preferredKey,
  );
  if (preferredIndex <= 0) {
    return ordered;
  }
  return <T>[
    ordered[preferredIndex],
    ...ordered.take(preferredIndex),
    ...ordered.skip(preferredIndex + 1),
  ];
}
