import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/services/subscription_profile_reconciler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const reconciler = SubscriptionProfileReconciler();
  const sourceA = 'https://example.com/subscription/a';
  const sourceB = 'https://example.com/subscription/b';

  test('replaces rotated subscription profiles and remaps selection', () {
    final oldHysteria = _profile(
      id: 'old-auth-id',
      source: sourceA,
      kind: VpnProfileKind.hysteria2,
      server: 'vpn.example.com',
      port: 8443,
      password: 'old-auth',
    );
    final refreshedHysteria = _profile(
      id: 'new-auth-id',
      source: sourceA,
      kind: VpnProfileKind.hysteria2,
      server: 'vpn.example.com',
      port: 8443,
      password: 'new-auth',
    );

    final result = reconciler.replaceRefreshedSources(
      existing: [oldHysteria],
      imported: [refreshedHysteria],
      refreshedSources: {sourceA},
      selectedProfileId: oldHysteria.id,
    );

    expect(result.profiles, [refreshedHysteria]);
    expect(result.selectedProfileId, refreshedHysteria.id);
  });

  test('retains manual profiles and profiles from a failed source', () {
    final manual = _profile(id: 'manual', source: null);
    final failedSourceProfile = _profile(id: 'source-b-old', source: sourceB);
    final oldSourceA = _profile(id: 'source-a-old', source: sourceA);
    final newSourceA = _profile(id: 'source-a-new', source: sourceA);

    final result = reconciler.replaceRefreshedSources(
      existing: [manual, oldSourceA, failedSourceProfile],
      imported: [newSourceA],
      refreshedSources: {sourceA},
      selectedProfileId: failedSourceProfile.id,
    );

    expect(result.profiles.map((profile) => profile.id), [
      'manual',
      'source-b-old',
      'source-a-new',
    ]);
    expect(result.selectedProfileId, failedSourceProfile.id);
  });

  test('deduplicates imported profiles by id', () {
    final first = _profile(id: 'same', source: sourceA, password: 'old');
    final last = _profile(id: 'same', source: sourceA, password: 'new');

    final result = reconciler.replaceRefreshedSources(
      existing: const [],
      imported: [first, last],
      refreshedSources: {sourceA},
      selectedProfileId: null,
    );

    expect(result.profiles, hasLength(1));
    expect(result.profiles.single.outbound?['password'], 'new');
  });
}

VpnProfile _profile({
  required String id,
  required String? source,
  VpnProfileKind kind = VpnProfileKind.hysteria2,
  String server = 'vpn.example.com',
  int port = 443,
  String password = 'test-auth',
}) {
  return VpnProfile(
    id: id,
    name: '$server ${kind.name}',
    kind: kind,
    originalInput: source ?? 'hy2://test-auth@$server:$port',
    server: server,
    port: port,
    outbound: {
      'type': 'hysteria2',
      'server': server,
      'server_port': port,
      'password': password,
    },
    subscriptionSource: source,
  );
}
