import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/profile_country_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

VpnProfile profile(String name, {String cachedCode = 'DE'}) => VpnProfile(
  id: 'location-fixture',
  name: name,
  kind: VpnProfileKind.naive,
  originalInput: 'naive+https://example.test',
  server: 'edge.example.test',
  port: 443,
  countryCode: cachedCode,
  countryName: 'Germany',
);

void main() {
  for (final entry in <String, String>{
    '\u{1F1E8}\u{1F1FF} Prague': 'CZ',
    '\u{1F1F7}\u{1F1F4} Bucharest': 'RO',
    '\u{1F1E8}\u{1F1ED} Switzerland': 'CH',
    'Amsterdam / HTTPS': 'NL',
    'Prague / Reality': 'CZ',
    'Bucharest / Turbo': 'RO',
    '\u{1F310} Switzerland / Turbo': 'CH',
    'UK2 / Turbo': 'GB',
  }.entries) {
    test('declared location wins over cached geo: ${entry.key}', () {
      final value = profile(entry.key);
      expect(ProfileCountryResolver.displayCountryCode(value), entry.value);
      expect(ProfileCountryResolver.hasDeclaredCountry(value), isTrue);
    });
  }

  test('every valid regional flag yields its own ISO code', () {
    expect(
      ProfileCountryResolver.countryCodeFromFlag('\u{1F1EA}\u{1F1F8}'),
      'ES',
    );
    expect(
      ProfileCountryResolver.countryCodeFromFlag('\u{1F1E8}\u{1F1FF}'),
      'CZ',
    );
    expect(ProfileCountryResolver.countryCodeFromFlag('\u{1F310}'), isNull);
    expect(ProfileCountryResolver.countryCodeFromFlag('\u{1F1E8}'), isNull);
    expect(ProfileCountryResolver.countryCodeFromFlag(null), isNull);
  });

  test('unknown declared country never displays a conflicting cached name', () {
    final value = profile('\u{1F1EA}\u{1F1F8} Example');
    expect(ProfileCountryResolver.displayCountryCode(value), 'ES');
    expect(ProfileCountryResolver.displayCountryName(value), isNot('Germany'));
  });

  test('UK substring in a username is not a declared country', () {
    final value = profile('Proxy for Sukhoi');
    expect(ProfileCountryResolver.hasDeclaredCountry(value), isFalse);
    expect(ProfileCountryResolver.displayCountryCode(value), 'DE');
  });

  test('explicit flag retains priority over a route name', () {
    final value = profile('\u{1F1EC}\u{1F1E7} Relay via Poland');
    expect(ProfileCountryResolver.displayCountryCode(value), 'GB');
  });
}
