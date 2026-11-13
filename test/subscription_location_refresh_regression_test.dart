import 'dart:convert';

import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/profile_country_resolver.dart';
import 'package:aurum_vpn/src/services/profile_importer.dart';
import 'package:aurum_vpn/src/services/subscription_profile_reconciler.dart';
import 'package:flutter_test/flutter_test.dart';

const source = 'https://subscription.example/s/fixture/';

List<String> fixtureLinks() {
  final links = <String>[];
  for (final node in [
    'poland',
    'uk2',
    'prague',
    'bucharest',
    'fin',
    'amsterdam',
  ]) {
    final host = '$node.example';
    final label = Uri.encodeComponent(
      node == 'amsterdam' ? '\u{1F1F3}\u{1F1F1} Amsterdam' : node,
    );
    links.add('naive+https://fixture:password@$host:443#$label');
    links.add('hy2://fixture@$host:${node == 'uk2' ? 8443 : 443}#$label');
    links.add(
      'vless://11111111-1111-4111-8111-111111111111@$host:443?security=reality&type=tcp&sni=example.com&pbk=fixture&fp=firefox#$label',
    );
    links.add(
      'vless://11111111-1111-4111-8111-111111111111@$host:443?security=tls&type=xhttp&sni=$host&path=%2Fstream#$label',
    );
  }
  return links;
}

void main() {
  test(
    'imports six locations including Amsterdam Naive from raw and HTML',
    () async {
      final links = fixtureLinks();
      for (final payload in [
        links.join('\n'),
        '<html><body><textarea>${const HtmlEscape(HtmlEscapeMode.element).convert(links.join('\n'))}</textarea></body></html>',
      ]) {
        final profiles = await ProfileImporter().importFromText(payload);
        expect(profiles, hasLength(24));
        expect(
          profiles.where((p) => p.kind == VpnProfileKind.naive),
          hasLength(6),
        );
        expect(
          profiles.where((p) => p.server == 'amsterdam.example'),
          hasLength(4),
        );
      }
    },
  );

  test(
    'refresh removes retired Swiss and remaps renamed Amsterdam Naive',
    () async {
      final importer = ProfileImporter();
      final old =
          (await importer.importFromText(
            'naive+https://fixture:password@amsterdam.example:443#Netherlands',
          )).single.copyWith(
            subscriptionSource: source,
            countryCode: 'DE',
            countryName: 'Germany',
          );
      final swiss = (await importer.importFromText(
        'hy2://fixture@switzerland.example:443#Switzerland',
      )).single.copyWith(subscriptionSource: source);
      final imported = (await importer.importFromText(
        fixtureLinks().join('\n'),
      )).map((p) => p.copyWith(subscriptionSource: source)).toList();
      final result = const SubscriptionProfileReconciler()
          .replaceRefreshedSources(
            existing: [old, swiss],
            imported: imported,
            refreshedSources: {source},
            selectedProfileId: old.id,
          );
      expect(result.profiles, hasLength(24));
      expect(
        result.profiles.any((p) => p.server == 'switzerland.example'),
        isFalse,
      );
      final naive = result.profiles.singleWhere(
        (p) =>
            p.server == 'amsterdam.example' && p.kind == VpnProfileKind.naive,
      );
      expect(result.selectedProfileId, naive.id);
      expect(ProfileCountryResolver.displayCountryCode(naive), 'NL');
    },
  );
}
