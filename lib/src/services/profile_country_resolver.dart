import '../models/vpn_profile.dart';
import 'profile_geo_service.dart';

class ProfileCountryResolver {
  const ProfileCountryResolver._();

  static String? displayCountryName(VpnProfile? profile) {
    if (profile == null) {
      return null;
    }

    final declaredName = countryNameFromFlag(declaredCountryFlag(profile));
    if (declaredName != null) {
      return declaredName;
    }

    final countryName = profile.countryName?.trim();
    if (countryName != null && countryName.isNotEmpty) {
      return countryName;
    }

    return countryNameFromFlag(
      ProfileGeo.countryCodeToFlag(profile.countryCode),
    );
  }

  static String? displayCountryCode(VpnProfile? profile) {
    if (profile == null) {
      return null;
    }

    final declaredCode = countryCodeFromFlag(declaredCountryFlag(profile));
    if (declaredCode != null) {
      return declaredCode;
    }

    final cachedCode = profile.countryCode?.trim().toUpperCase();
    if (cachedCode != null &&
        cachedCode.length == 2 &&
        ProfileGeo.countryCodeToFlag(cachedCode) != null) {
      return cachedCode;
    }

    return countryCodeFromFlag(displayCountryFlag(profile));
  }

  static String? displayCountryFlag(VpnProfile? profile) {
    if (profile == null) {
      return null;
    }

    final declaredFlag = declaredCountryFlag(profile);
    if (declaredFlag != null) {
      return declaredFlag;
    }

    return ProfileGeo.countryCodeToFlag(profile.countryCode) ?? '🌐';
  }

  static bool hasDeclaredCountry(VpnProfile profile) {
    return declaredCountryFlag(profile) != null;
  }

  static String? declaredCountryFlag(VpnProfile profile) {
    final existing = leadingFlag(profile.name);
    if (existing != null) {
      return existing;
    }

    final haystack = '${profile.name} ${profile.server ?? ''}'.toLowerCase();
    if (haystack.contains('росси') ||
        haystack.contains('russia') ||
        haystack.endsWith('.ru') ||
        haystack.endsWith('.su') ||
        haystack.endsWith('.рф')) {
      return '🇷🇺';
    }
    if (haystack.contains('фин') ||
        haystack.contains('finland') ||
        haystack.endsWith('.fi')) {
      return '🇫🇮';
    }
    if (haystack.contains('герман') ||
        haystack.contains('germany') ||
        haystack.endsWith('.de')) {
      return '🇩🇪';
    }
    if (haystack.contains('поль') ||
        haystack.contains('poland') ||
        haystack.endsWith('.pl')) {
      return '🇵🇱';
    }
    if (haystack.contains('сша') ||
        haystack.contains('usa') ||
        haystack.contains('america') ||
        haystack.endsWith('.us')) {
      return '🇺🇸';
    }
    if (haystack.contains('japan') || haystack.contains('япон')) {
      return '🇯🇵';
    }
    if (haystack.contains('netherlands') || haystack.contains('нидер')) {
      return '🇳🇱';
    }
    if (haystack.contains('france') || haystack.contains('франц')) {
      return '🇫🇷';
    }
    if (haystack.contains('canada') || haystack.contains('канада')) {
      return '🇨🇦';
    }
    if (haystack.contains('turkey') || haystack.contains('турц')) {
      return '🇹🇷';
    }
    if (haystack.contains('uk') ||
        haystack.contains('united kingdom') ||
        haystack.endsWith('.co.uk')) {
      return '🇬🇧';
    }
    return null;
  }

  static String? countryNameFromFlag(String? flag) {
    return switch (flag) {
      '🇷🇺' => 'Россия',
      '🇫🇮' => 'Финляндия',
      '🇩🇪' => 'Германия',
      '🇵🇱' => 'Польша',
      '🇺🇸' => 'США',
      '🇯🇵' => 'Япония',
      '🇳🇱' => 'Нидерланды',
      '🇫🇷' => 'Франция',
      '🇨🇦' => 'Канада',
      '🇹🇷' => 'Турция',
      '🇬🇧' => 'Великобритания',
      _ => null,
    };
  }

  static String? countryCodeFromFlag(String? flag) {
    return switch (flag) {
      '🇷🇺' => 'RU',
      '🇫🇮' => 'FI',
      '🇩🇪' => 'DE',
      '🇵🇱' => 'PL',
      '🇺🇸' => 'US',
      '🇯🇵' => 'JP',
      '🇳🇱' => 'NL',
      '🇫🇷' => 'FR',
      '🇨🇦' => 'CA',
      '🇹🇷' => 'TR',
      '🇬🇧' => 'GB',
      _ => null,
    };
  }

  static String? leadingFlag(String value) {
    final runes = value.trimLeft().runes.take(2).toList(growable: false);
    if (runes.length < 2) {
      return null;
    }
    final isFlag = runes.every((rune) => rune >= 0x1F1E6 && rune <= 0x1F1FF);
    return isFlag ? String.fromCharCodes(runes) : null;
  }
}
