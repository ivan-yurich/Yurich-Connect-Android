import 'dart:convert';

class RuntimeConfigMatcher {
  const RuntimeConfigMatcher._();

  static bool equivalent(String current, String expected) {
    if (current == expected) {
      return true;
    }

    try {
      return jsonEncode(_normalize(jsonDecode(current))) ==
          jsonEncode(_normalize(jsonDecode(expected)));
    } on FormatException {
      return current.trim() == expected.trim();
    }
  }

  static Object? _normalize(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => '$key').toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: _normalize(value[key]),
      };
    }
    if (value is List) {
      return value.map(_normalize).toList(growable: false);
    }
    return value;
  }
}
