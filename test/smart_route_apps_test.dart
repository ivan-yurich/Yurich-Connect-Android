import 'dart:convert';
import 'dart:io';

import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/screens/smart_route_apps_dialog.dart';
import 'package:aurum_vpn/src/services/smart_route_apps_service.dart';
import 'package:aurum_vpn/src/services/smart_route_rules.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _maxId = 'ru.oneme.app';
const _sberId = 'ru.sberbankmobile';
const _bankId = 'ru.bspb';
const _max = SmartRouteAppCandidate(
  _maxId,
  'MAX',
  SmartRouteAppAvailability.missing,
);
const _sber = SmartRouteAppCandidate(
  _sberId,
  'СберБанк Онлайн',
  SmartRouteAppAvailability.installed,
);
const _bank = SmartRouteAppCandidate(
  _bankId,
  'БСПБ',
  SmartRouteAppAvailability.installed,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'APK catalog and narrow package visibility match the verified source exactly',
    () {
      List<Map> readCatalog(String path) {
        final source = jsonDecode(File(path).readAsStringSync()) as Map;
        return (source['verified_android_candidates'] as List).cast<Map>();
      }

      final baseline = readCatalog(
        'docs/SMART_ROUTE_RU_BANK_CATALOG_2026-11-11.json',
      );
      final additions = readCatalog(
        'docs/SMART_ROUTE_RU_PUBLIC_APPS_2026-11-12.json',
      );
      final expansion = readCatalog(
        'docs/SMART_ROUTE_RU_CATALOG_EXPANSION_2026-11-12.json',
      );
      final ruStoreTop = readCatalog(
        'docs/SMART_ROUTE_RU_RUSTORE_TOP_2026-11-12.json',
      );
      expect(baseline.length, 14);
      expect(additions.length, 39);
      for (final item in additions) {
        expect(
          item['source_url'],
          "https://www.rustore.ru/catalog/app/${item['package_id']}",
        );
        expect(item['category'], isIn(['social', 'government']));
      }
      expect(expansion.length, 48);
      for (final item in expansion) {
        final url = Uri.parse(item['source_url'] as String);
        expect(url.scheme, 'https');
        expect(url.host, isNotEmpty);
        expect(url.userInfo, isEmpty);
        expect(
          item['category'],
          isIn(['government', 'social', 'related', 'state_company', 'service']),
        );
        if (url.host == 'www.rustore.ru') {
          expect(url.path, "/catalog/app/${item['package_id']}");
        } else if (url.host == 'play.google.com') {
          expect(url.path, '/store/apps/details');
          expect(url.queryParameters['id'], item['package_id']);
        }
      }
      expect(ruStoreTop.length, 24);
      for (final item in ruStoreTop) {
        expect(
          item['source_url'],
          "https://www.rustore.ru/catalog/app/${item['package_id']}",
        );
        expect(
          item['store_collection'],
          isIn(['Обе', 'Популярное', 'Топ установок']),
        );
      }
      final entries = [...baseline, ...additions, ...expansion, ...ruStoreTop];
      final approved = {
        for (final item in entries) item['package_id']: item['name'],
      };
      final packaged =
          (jsonDecode(
                    File(
                      'plugins/flutter_singbox_vpn/android/src/main/assets/smart_route_android_candidates.json',
                    ).readAsStringSync(),
                  )
                  as List)
              .cast<Map>();
      expect(approved.length, entries.length, reason: 'Duplicate package IDs');
      expect(packaged.length, approved.length);
      expect({
        for (final item in packaged) item['packageId']: item['name'],
      }, approved);
      expect(approved[_maxId], 'MAX');
      expect(approved['com.vkontakte.android'], 'ВКонтакте');
      expect(approved['ru.ok.android'], 'Одноклассники');
      expect(approved['ru.rostel'], 'Госуслуги');
      expect(approved['com.gnivts.selfemployed'], 'Мой налог');
      expect(approved['website.copyandpaste.MFCRO'], 'МФЦ Ростовской области');
      expect(approved, isNot(contains('website.copyandpaste.mfcro')));
      expect(approved, isNot(contains('com.yandex.browser')));
      expect(approved, isNot(contains('ru.yandex.searchplugin')));
      expect(approved, isNot(contains('com.yandex.searchapp')));
      expect(approved, isNot(contains('ru.ok.messages')));
      expect(approved['ru.nspk.mirpay'], 'Mir Pay');
      expect(approved['ru.dublgis.dgismobile'], '2ГИС');
      expect(approved, isNot(contains('com.pachca.app')));
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      final declared = RegExp(
        r'<package android:name="([^"]+)"\s*/>',
      ).allMatches(manifest).map((match) => match[1]).toSet();
      expect(declared, approved.keys.toSet());
      expect(manifest, isNot(contains('QUERY_ALL_PACKAGES')));
      final builtIn = SmartRouteRules.ruBypassPackages(const []);
      final ruStoreTopIds = ruStoreTop
          .map((item) => item['package_id'])
          .toSet();
      expect(ruStoreTopIds.intersection(builtIn.toSet()), isEmpty);
      expect(
        approved.keys.toSet().intersection(
          SmartRouteRules.ruBypassDenyPackageNames.toSet(),
        ),
        isEmpty,
      );
      expect(builtIn, containsAll(['com.vkontakte.android', 'ru.ok.android']));
      expect(builtIn, isNot(contains(_maxId)));
      expect(builtIn, isNot(contains(_bankId)));
    },
  );

  test(
    'default selection is empty and state accepts exact catalog IDs only',
    () {
      expect(const SmartRouteAppsSnapshot().selected, isEmpty);
      final snapshot = SmartRouteAppsSnapshot.fromMap({
        'candidates': [
          {'packageId': _maxId, 'name': 'MAX', 'availability': 'missing'},
        ],
        'selected': [
          _maxId,
          'ru.oneme.app.clone',
          'RU.ONEME.APP',
          ' ru.oneme.app',
        ],
      });
      expect(snapshot.selected, {_maxId});
      expect(
        snapshot.candidates.single.availability,
        SmartRouteAppAvailability.missing,
      );
    },
  );

  test('expanded catalog preserves case and full live exclusion evidence', () {
    const mixedCase = 'website.copyandpaste.MFCRO';
    final candidates = [
      for (
        var index = 0;
        index < SmartRouteAppsSnapshot.maxCandidates - 1;
        index++
      )
        'test.apps.entry$index',
      mixedCase,
    ];
    final rows = [
      for (final id in candidates)
        {'packageId': id, 'name': id, 'availability': 'installed'},
    ];
    final applied = [
      ...candidates,
      for (var index = 0; index < 64; index++) 'test.builtin.entry$index',
    ];
    final snapshot = SmartRouteAppsSnapshot.fromMap({
      'candidates': rows,
      'selected': candidates,
      'applied': applied,
    });
    expect(snapshot.candidates.length, 128);
    expect(snapshot.selected, candidates.toSet());
    expect(snapshot.selected, isNot(contains(mixedCase.toLowerCase())));
    expect(snapshot.applied, applied.toSet());
    final oversized = SmartRouteAppsSnapshot.fromMap({
      'candidates': [
        ...rows,
        {'packageId': 'test.extra'},
      ],
      'applied': [...applied, 'test.extra'],
    });
    expect(oversized.candidates, isEmpty);
    expect(oversized.applied, isNull);
  });

  test('applied means live evidence; protection outranks stale exclusions', () {
    SmartRouteAppRoute state(
      SmartRouteAppsSnapshot snapshot, {
      bool enabled = true,
      bool managed = true,
    }) => snapshot.routeFor(
      _maxId,
      builtIn: false,
      smartRouteEnabled: enabled,
      managedProfile: managed,
      vpnActive: true,
    );
    expect(
      state(
        const SmartRouteAppsSnapshot(
          selected: {_maxId},
          applied: {_maxId},
          supported: true,
          protectionKnown: true,
        ),
      ),
      SmartRouteAppRoute.applied,
    );
    expect(
      state(
        const SmartRouteAppsSnapshot(
          selected: {_maxId},
          applied: {_maxId},
          supported: true,
          protectionKnown: true,
          protected: true,
        ),
      ),
      SmartRouteAppRoute.protected,
    );
    const pending = SmartRouteAppsSnapshot(selected: {_maxId}, supported: true);
    expect(state(pending), SmartRouteAppRoute.unconfirmed);
    expect(state(pending, enabled: false), SmartRouteAppRoute.smartRouteOff);
    expect(state(pending, managed: false), SmartRouteAppRoute.rawProfile);
    expect(
      state(
        const SmartRouteAppsSnapshot(
          selected: {_maxId},
          supported: true,
          legacyAppMode: true,
        ),
      ),
      SmartRouteAppRoute.otherAppMode,
    );
  });

  test(
    'managed configuration marker is a private call parameter, not a JSON field',
    () async {
      const channel = MethodChannel('com.tecclub.flutter_singbox/methods');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      const service = SmartRouteAppsService();
      const config = '{"synthetic":true}';
      expect(await service.saveManagedConfig(config), isTrue);
      expect(calls.single.method, 'saveConfig');
      expect(calls.single.arguments, {
        'config': config,
        'smartRouteApps': true,
      });
      expect(
        SmartRouteAppsService.managedProfile(
          const VpnProfile(
            id: 'raw',
            name: 'Raw',
            kind: VpnProfileKind.singBoxConfig,
            originalInput: '{}',
            rawConfig: '{}',
          ),
        ),
        isFalse,
      );
      await service.clearBinding();
      expect(calls.last.method, 'clearSmartRouteAppBinding');
    },
  );

  Future<void> open(
    WidgetTester tester, {
    required SmartRouteAppsSnapshot snapshot,
    required void Function(Set<String>?) onSave,
    bool smartRouteEnabled = true,
    bool vpnActive = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => onSave(
                await showDialog<Set<String>>(
                  context: context,
                  builder: (_) => SmartRouteAppsDialog(
                    snapshot: snapshot,
                    builtInPackages: const {_sberId},
                    smartRouteEnabled: smartRouteEnabled,
                    managedProfile: true,
                    vpnActive: vpnActive,
                    russian: true,
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('clean-install catalog shows all 125 choices checked', (
    tester,
  ) async {
    final catalog =
        (jsonDecode(
                  File(
                    'plugins/flutter_singbox_vpn/android/src/main/assets/smart_route_android_candidates.json',
                  ).readAsStringSync(),
                )
                as List)
            .cast<Map>();
    final snapshot = SmartRouteAppsSnapshot.fromMap({
      'candidates': [
        for (final row in catalog) {...row, 'availability': 'missing'},
      ],
      'selected': [for (final row in catalog) row['packageId']],
      'supported': true,
      'protectionKnown': true,
    });
    await open(
      tester,
      snapshot: snapshot,
      smartRouteEnabled: false,
      vpnActive: false,
      onSave: (_) => fail('Viewing defaults must not save anything'),
    );
    expect(find.text('Выбрано: 125 из 125'), findsOneWidget);
    final rows = tester.widgetList<CheckboxListTile>(
      find.byWidgetPredicate(
        (widget) =>
            widget is CheckboxListTile &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'smart-route-app-',
            ),
      ),
    );
    expect(rows, hasLength(125));
    expect(rows.every((row) => row.value == true), isTrue);
    expect(find.text('Напрямую · применено'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'MAX is selectable; absent packages and existing exclusions are labelled',
    (tester) async {
      Set<String>? result;
      await open(
        tester,
        snapshot: const SmartRouteAppsSnapshot(
          candidates: [_max, _sber, _bank],
          applied: {_sberId},
          supported: true,
          protectionKnown: true,
        ),
        onSave: (value) => result = value,
      );
      final max = find.byKey(const ValueKey('smart-route-app-ru.oneme.app'));
      final bank = find.byKey(const ValueKey('smart-route-app-ru.bspb'));
      expect(tester.widget<CheckboxListTile>(max).value, isFalse);
      expect(tester.widget<CheckboxListTile>(bank).value, isFalse);
      expect(find.text('Не установлено · не применяется'), findsOneWidget);
      final sber = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('smart-route-app-ru.sberbankmobile')),
      );
      expect(sber.value, isTrue);
      expect(sber.onChanged, isNull);
      expect(find.text('Встроенные исключения (1)'), findsNothing);
      expect(find.text('Напрямую · применено'), findsOneWidget);
      await tester.ensureVisible(max);
      await tester.tap(max);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить и переподключить'));
      await tester.pumpAndSettle();
      expect(result, {_maxId});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'strict protection preserves selection without advertising direct traffic',
    (tester) async {
      await open(
        tester,
        snapshot: const SmartRouteAppsSnapshot(
          candidates: [_max, _bank],
          selected: {_bankId},
          applied: {_bankId},
          supported: true,
          protectionKnown: true,
          protected: true,
        ),
        onSave: (_) {},
      );
      expect(find.text('Напрямую · применено'), findsNothing);
      expect(find.text('Приостановлено защитой'), findsNWidgets(2));
      expect(find.text('Сохранить и переподключить'), findsNothing);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('smart-route-app-ru.bspb')),
            )
            .value,
        isTrue,
      );
    },
  );
}
