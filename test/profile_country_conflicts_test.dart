import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/profile_country_resolver.dart';
import 'package:aurum_vpn/src/services/profile_geo_service.dart';
import 'package:flutter_test/flutter_test.dart';

VpnProfile _profile(
  String name, {
  String server = 'edge.ru',
  String? code,
  String? country,
}) => VpnProfile(
  id: 'country-conflict-fixture',
  name: name,
  kind: VpnProfileKind.hysteria2,
  originalInput: '',
  server: server,
  countryCode: code,
  countryName: country,
);

void main() {
  test(
    'code-only Geo update replaces an old country name instead of retaining it',
    () {
      expect(
        ProfileCountryResolver.countryNameForGeo(
          const ProfileGeo(countryCode: 'PL'),
        ),
        'Польша',
      );
      expect(
        ProfileCountryResolver.countryNameForGeo(
          const ProfileGeo(countryCode: 'PL', countryName: 'Germany'),
        ),
        'Польша',
      );
      expect(
        ProfileCountryResolver.countryNameForGeo(
          const ProfileGeo(countryCode: 'DE', countryName: 'Germany'),
        ),
        'Germany',
      );
    },
  );
  test('explicit profile location wins over the endpoint country-code TLD', () {
    final profile = _profile(
      'Amsterdam / Turbo',
      code: 'DE',
      country: 'Germany',
    );
    expect(ProfileCountryResolver.displayCountryCode(profile), 'NL');
    expect(ProfileCountryResolver.displayCountryName(profile), 'Нидерланды');
  });

  test('a country-code TLD alone is not a declared server location', () {
    final profile = _profile('Fast proxy', code: 'DE', country: 'Germany');
    expect(ProfileCountryResolver.hasDeclaredCountry(profile), isFalse);
    expect(ProfileCountryResolver.displayCountryCode(profile), 'DE');
  });

  test(
    'country substrings inside unrelated words do not override cached geo',
    () {
      for (final name in [
        'Финансовый сервис',
        'Proxy for Sukhoi',
        'CanadaDry relay',
        'Swisscomet',
        'Прагматичный сервер',
        'Даниил proxy',
        'Сан-Франциско',
      ]) {
        final profile = _profile(
          name,
          server: 'edge.example',
          code: 'DE',
          country: 'Germany',
        );
        expect(
          ProfileCountryResolver.hasDeclaredCountry(profile),
          isFalse,
          reason: name,
        );
        expect(
          ProfileCountryResolver.displayCountryCode(profile),
          'DE',
          reason: name,
        );
      }
    },
  );

  test(
    'ambiguous route names do not pick a country by hard-coded ordering',
    () {
      final profile = _profile(
        'Germany via Poland',
        server: 'edge.example',
        code: 'FR',
        country: 'France',
      );
      expect(ProfileCountryResolver.hasDeclaredCountry(profile), isFalse);
      expect(ProfileCountryResolver.displayCountryCode(profile), 'FR');
    },
  );

  test(
    'flag, ISO code and cached name cannot describe different countries',
    () {
      final profile = _profile(
        'Proxy',
        server: 'edge.example',
        code: 'DE',
        country: 'Poland',
      );
      expect(ProfileCountryResolver.displayCountryCode(profile), 'DE');
      expect(ProfileCountryResolver.displayCountryFlag(profile), '🇩🇪');
      expect(ProfileCountryResolver.displayCountryName(profile), 'Германия');
    },
  );

  test(
    'embedded explicit flag wins and copied profile invalidates display cache',
    () {
      final old = _profile(
        'Proxy 🇪🇸',
        server: 'edge.example',
        code: 'DE',
        country: 'Germany',
      );
      expect(ProfileCountryResolver.displayCountryCode(old), 'ES');
      final updated = old.copyWith(name: '🇫🇷 Paris');
      expect(ProfileCountryResolver.displayCountryCode(updated), 'FR');
      expect(ProfileCountryResolver.displayCountryCode(old), 'ES');
    },
  );
}
