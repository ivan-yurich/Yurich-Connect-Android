import 'package:flutter_test/flutter_test.dart';
import 'package:aurum_vpn/src/services/profile_geo_service.dart';

void main() {
  test('converts ISO country code to flag emoji', () {
    expect(ProfileGeo.countryCodeToFlag('FI'), '🇫🇮');
    expect(ProfileGeo.countryCodeToFlag('ru'), '🇷🇺');
    expect(ProfileGeo.countryCodeToFlag('USA'), isNull);
    expect(ProfileGeo.countryCodeToFlag(''), isNull);
  });

  test('geo flag normalizes a valid code and falls back for invalid codes', () {
    expect(const ProfileGeo(countryCode: ' fi ').flag, '🇫🇮');
    for (final code in ['', 'USA', '0A']) {
      expect(ProfileGeo(countryCode: code).flag, '🌐', reason: code);
    }
  });
}
