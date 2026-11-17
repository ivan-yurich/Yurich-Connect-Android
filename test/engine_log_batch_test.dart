import 'package:aurum_vpn/src/services/engine_log_batch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('background flush bounds stored logs and preserves their order', () {
    final pending = ['second', 'third'];
    final stored = ['first'];
    EngineLogBatch.flush(
      pending: pending,
      stored: stored,
      limit: 2,
      publish: null,
      onError: (_, error, _) => fail('$error'),
    );
    expect(stored, ['second', 'third']);
    expect(pending, isEmpty);
  });

  test('empty batch is not published', () {
    final stored = ['first'];
    EngineLogBatch.flush(
      pending: [],
      stored: stored,
      limit: 2,
      publish: (_) => fail('Unexpected publish for an empty batch'),
      onError: (_, error, _) => fail('$error'),
    );
    expect(stored, ['first']);
  });

  test('a rejected log publication reports the error and can be retried', () {
    final pending = ['second'];
    final stored = ['first'];
    final refusal = StateError('Fixture: publisher unavailable');
    final errors = <(String, Object, StackTrace)>[];
    void flush(void Function(void Function()) publish) {
      EngineLogBatch.flush(
        pending: pending,
        stored: stored,
        limit: 2,
        publish: publish,
        onError: (source, error, stack) => errors.add((source, error, stack)),
      );
    }

    flush((_) => throw refusal);
    expect(errors.single.$1, 'log-flush');
    expect(errors.single.$2, same(refusal));
    expect(errors.single.$3.toString(), isNotEmpty);
    expect(stored, ['first']);
    expect(pending, ['second']);

    flush((commit) => commit());
    expect(errors, hasLength(1));
    expect(stored, ['first', 'second']);
    expect(pending, isEmpty);
  });
}
