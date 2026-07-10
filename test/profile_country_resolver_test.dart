import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/profile_country_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProfileCountryResolver', () {
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
