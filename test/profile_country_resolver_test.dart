import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/profile_country_resolver.dart';
import 'package:aurum_vpn/src/services/profile_geo_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProfileCountryResolver', () {
    test('declared flag remains distinct from cached geo and host hints', () {
      const profile = VpnProfile(
        id: 'declared-flag-fixture',
        name: '🇰🇿 Netherlands relay',
        kind: VpnProfileKind.naive,
        originalInput: '',
        server: 'germany.edge.example.invalid',
        countryCode: 'PL',
        countryName: 'Poland',
      );

      expect(ProfileCountryResolver.declaredCountryFlag(profile), '🇰🇿');
      expect(ProfileCountryResolver.displayCountryFlag(profile), '🇰🇿');
      expect(ProfileCountryResolver.displayCountryCode(profile), 'KZ');
      expect(ProfileCountryResolver.displayCountryName(profile), 'Казахстан');
    });

    test('does not promote cached geo or a host hint to a declared flag', () {
      for (final (server, cached, displayed) in [
        ('edge.example.invalid', 'PL', '🇵🇱'),
        ('finland.edge.example.invalid', null, '🇫🇮'),
      ]) {
        final profile = VpnProfile(
          id: 'derived-flag-fixture',
          name: 'Synthetic relay',
          kind: VpnProfileKind.naive,
          originalInput: '',
          server: server,
          countryCode: cached,
        );

        expect(ProfileCountryResolver.declaredCountryFlag(profile), isNull);
        expect(ProfileCountryResolver.hasDeclaredCountry(profile), isFalse);
        expect(ProfileCountryResolver.displayCountryFlag(profile), displayed);
      }
    });

    test('uses the geo code if no matching country name is available', () {
      const fixtureCode = 'QZ'; // No entry in the display-name dictionary.
      for (final name in [null, '  ', 'Germany']) {
        expect(
          ProfileCountryResolver.countryNameForGeo(
            ProfileGeo(countryCode: fixtureCode, countryName: name),
          ),
          fixtureCode,
        );
      }
    });

    test('prefers subscription flag over stale cached geo country', () {
      const profile = VpnProfile(
        id: 'poland-reality',
        name: '🇵🇱 Poland • Xray REALITY TCP',
        kind: VpnProfileKind.vlessReality,
        originalInput: 'vless://example',
        server: 'plus-dns.tech',
        port: 443,
        countryCode: 'DE',
        countryName: 'Germany',
      );

      expect(ProfileCountryResolver.displayCountryFlag(profile), '🇵🇱');
      expect(ProfileCountryResolver.displayCountryCode(profile), 'PL');
      expect(ProfileCountryResolver.displayCountryName(profile), 'Польша');
      expect(ProfileCountryResolver.hasDeclaredCountry(profile), isTrue);
    });

    test('detects Poland from profile name without leading flag', () {
      const profile = VpnProfile(
        id: 'poland-naive',
        name: 'Poland • Yurich Proxy',
        kind: VpnProfileKind.naive,
        originalInput: 'naive+https://example',
        server: 'plus-dns.tech',
        port: 443,
        countryCode: 'DE',
        countryName: 'Germany',
      );

      expect(ProfileCountryResolver.displayCountryFlag(profile), '🇵🇱');
      expect(ProfileCountryResolver.displayCountryCode(profile), 'PL');
      expect(ProfileCountryResolver.displayCountryName(profile), 'Польша');
    });

    test('uses cached geo when profile has no declared country', () {
      const profile = VpnProfile(
        id: 'unknown',
        name: 'Yurich Proxy',
        kind: VpnProfileKind.naive,
        originalInput: 'naive+https://example',
        server: 'plus-dns.tech',
        port: 443,
        countryCode: 'DE',
        countryName: 'Germany',
      );

      expect(ProfileCountryResolver.displayCountryFlag(profile), '🇩🇪');
      expect(ProfileCountryResolver.displayCountryCode(profile), 'DE');
      expect(ProfileCountryResolver.displayCountryName(profile), 'Germany');
    });
  });
}
