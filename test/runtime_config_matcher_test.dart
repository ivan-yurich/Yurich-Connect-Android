import 'dart:convert';

import 'package:aurum_vpn/src/services/runtime_config_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('matches equivalent runtime JSON independent of formatting', () {
    const current =
        '{"outbounds":[{"server":"fi.example","port":443}],"log":{"level":"warn"}}';
    const expected = '''
      {
        "log": {"level": "warn"},
        "outbounds": [{"port": 443, "server": "fi.example"}]
      }
    ''';

    expect(RuntimeConfigMatcher.equivalent(current, expected), isTrue);
  });

  test('rejects a runtime config for another selected endpoint', () {
    const current = '{"outbounds":[{"server":"pl.example","port":443}]}';
    const expected = '{"outbounds":[{"server":"fi.example","port":443}]}';

    expect(RuntimeConfigMatcher.equivalent(current, expected), isFalse);
  });

  test('does not ignore a change in route-rule precedence', () {
    const rules = [
      {
        'domain': ['fixture.invalid'],
        'outbound': 'proxy',
      },
      {'action': 'reject'},
    ];
    String config(Iterable<Map<String, Object>> orderedRules) => jsonEncode({
      'route': {'rules': orderedRules.toList()},
    });

    expect(
      RuntimeConfigMatcher.equivalent(config(rules), config(rules.reversed)),
      isFalse,
    );
  });

  test(
    'does not treat a different certificate validation flag as equivalent',
    () {
      String config(bool insecure) => jsonEncode({
        'outbounds': [
          {
            'tls': {'enabled': true, 'insecure': insecure},
          },
        ],
      });

      expect(
        RuntimeConfigMatcher.equivalent(config(false), config(true)),
        isFalse,
      );
    },
  );

  test('falls back to trimmed comparison for non-JSON configs', () {
    expect(
      RuntimeConfigMatcher.equivalent(' raw-config ', 'raw-config'),
      isTrue,
    );
    expect(
      RuntimeConfigMatcher.equivalent(' route=proxy ', 'route=direct'),
      isFalse,
    );
  });
}
