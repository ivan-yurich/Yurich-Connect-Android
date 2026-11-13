import '../models/vpn_profile.dart';
import 'profile_geo_service.dart';

class ProfileCountryResolver {
  const ProfileCountryResolver._();

  // Immutable profile copies get fresh results; the weak cache cannot retain
  // removed profiles. Flags, labels and ISO codes share one coherent decision.
  static final _cache = Expando<_CountryDisplay>();
  static final _hints =
      {
        'RU': 'russia|росси[а-яё]*',
        'FI': 'fin|finland|финлянд(?:ия|ии|ию|ией)',
        'DE': 'germany|deutschland|германи(?:я|и|ю|ей)',
        'PL': 'poland|польш[а-яё]*',
        'US': 'usa|united states|america|сша',
        'JP': 'japan|япони[а-яё]*',
        'NL': 'netherlands|holland|amsterdam|нидерланд[а-яё]*|амстердам',
        'CH': 'switzerland|swiss|швейцари[а-яё]*',
        'CZ':
            'prague|praha|czech(?:ia| republic)?|праг(?:а|е|и|у|ой)|чехи[а-яё]*',
        'RO': 'bucharest|bucuresti|romania|бухарест|румыни[а-яё]*',
        'FR': 'france|франци(?:я|и|ю|ей)',
        'CA': 'canada|канад[а-яё]*',
        'TR': 'turkey|türkiye|турци[а-яё]*',
        'GB': 'uk[0-9]*|united kingdom|britain|великобритани[а-яё]*',
        'ES': 'spain|испан[а-яё]*',
        'IT': 'italy|итали[а-яё]*',
        'SE': 'sweden|швеци[а-яё]*',
        'NO': 'norway|норвеги[а-яё]*',
        'DK': 'denmark|дани(?:я|и|ю|ей)',
        'AT': 'austria|австри[а-яё]*',
        'EE': 'estonia|эстони[а-яё]*',
        'LV': 'latvia|латви[а-яё]*',
        'LT': 'lithuania|литв[а-яё]*',
        'KZ': 'kazakhstan|казахстан',
        'AU': 'australia|австрали[а-яё]*',
        'SG': 'singapore|сингапур',
      }.map(
        (code, pattern) => MapEntry(
          code,
          RegExp(
            '(?:^|[^a-zа-яё])(?:$pattern)(?=\$|[^a-zа-яё])',
            caseSensitive: false,
          ),
        ),
      );
  static const _names = {
    'RU': 'Россия',
    'FI': 'Финляндия',
    'DE': 'Германия',
    'PL': 'Польша',
    'US': 'США',
    'JP': 'Япония',
    'NL': 'Нидерланды',
    'CH': 'Швейцария',
    'CZ': 'Чехия',
    'RO': 'Румыния',
    'FR': 'Франция',
    'CA': 'Канада',
    'TR': 'Турция',
    'GB': 'Великобритания',
    'ES': 'Испания',
    'IT': 'Италия',
    'SE': 'Швеция',
    'NO': 'Норвегия',
    'DK': 'Дания',
    'AT': 'Австрия',
    'EE': 'Эстония',
    'LV': 'Латвия',
    'LT': 'Литва',
    'KZ': 'Казахстан',
    'AU': 'Австралия',
    'SG': 'Сингапур',
  };

  static String? displayCountryName(VpnProfile? profile) =>
      profile == null ? null : _display(profile).name;
  static String? displayCountryCode(VpnProfile? profile) =>
      profile == null ? null : _display(profile).code;
  static String? displayCountryFlag(VpnProfile? profile) => profile == null
      ? null
      : ProfileGeo.countryCodeToFlag(_display(profile).code) ?? '🌐';
  static bool hasDeclaredCountry(VpnProfile profile) =>
      _display(profile).declaredCode != null;
  static String? declaredCountryFlag(VpnProfile profile) =>
      ProfileGeo.countryCodeToFlag(_display(profile).declaredCode);

  static _CountryDisplay _display(VpnProfile profile) =>
      _cache[profile] ??= _resolve(profile);

  static _CountryDisplay _resolve(VpnProfile profile) {
    final declared = _declaredCode(profile.name);
    final cached = ProfileGeo.countryCodeToFlag(profile.countryCode) == null
        ? null
        : profile.countryCode!.trim().toUpperCase();
    // A country-code TLD is a registration zone, not a physical location.
    // A hostname hint is weaker than Geo-IP and never freezes Geo updates.
    final code = declared ?? cached ?? _labelCode(profile.server ?? '');
    if (code == null) return const _CountryDisplay(null, null, null);
    final cachedName = profile.countryName?.trim();
    final cachedNameCode = _labelCode(cachedName ?? '');
    final coherentName =
        code == cached &&
            cachedName != null &&
            cachedName.isNotEmpty &&
            (cachedNameCode == null || cachedNameCode == code)
        ? cachedName
        : null;
    final name = declared != null
        ? _names[code] ?? coherentName ?? code
        : coherentName ?? _names[code] ?? code;
    return _CountryDisplay(code, name, declared);
  }

  static String? _labelCode(String text) {
    String? result;
    for (final entry in _hints.entries) {
      if (!entry.value.hasMatch(text)) continue;
      if (result != null && result != entry.key) return null;
      result = entry.key;
    }
    return result;
  }

  static String? _declaredCode(String name) {
    final leading = countryCodeFromFlag(leadingFlag(name));
    if (leading != null) return leading;
    final codes = <String>{};
    final runes = name.runes.toList(growable: false);
    for (var i = 0; i + 1 < runes.length; i++) {
      if (_regional(runes[i]) && _regional(runes[i + 1])) {
        codes.add(
          String.fromCharCodes([
            runes[i] - 0x1F1E6 + 0x41,
            runes[i + 1] - 0x1F1E6 + 0x41,
          ]),
        );
        i++;
      }
    }
    if (codes.isNotEmpty) return codes.length == 1 ? codes.single : null;
    return _labelCode(name);
  }

  static String? countryNameFromFlag(String? flag) =>
      _names[countryCodeFromFlag(flag)];

  static String countryNameForGeo(ProfileGeo geo) {
    final name = geo.countryName?.trim();
    final nameCode = _labelCode(name ?? '');
    if (name != null &&
        name.isNotEmpty &&
        (nameCode == null || nameCode == geo.countryCode)) {
      return name;
    }
    return countryNameFromFlag(ProfileGeo.countryCodeToFlag(geo.countryCode)) ??
        geo.countryCode;
  }

  static String? countryCodeFromFlag(String? flag) {
    final runes = flag?.runes.toList(growable: false);
    if (runes == null || runes.length != 2 || !runes.every(_regional)) {
      return null;
    }
    return String.fromCharCodes(runes.map((rune) => rune - 0x1F1E6 + 0x41));
  }

  static String? leadingFlag(String value) {
    final runes = value.trimLeft().runes.take(2).toList(growable: false);
    return runes.length == 2 && runes.every(_regional)
        ? String.fromCharCodes(runes)
        : null;
  }

  static bool _regional(int rune) => rune >= 0x1F1E6 && rune <= 0x1F1FF;
}

final class _CountryDisplay {
  const _CountryDisplay(this.code, this.name, this.declaredCode);
  final String? code;
  final String? name;
  final String? declaredCode;
}
