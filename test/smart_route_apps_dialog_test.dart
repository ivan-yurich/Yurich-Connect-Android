import 'package:aurum_vpn/src/screens/smart_route_apps_dialog.dart';
import 'package:aurum_vpn/src/services/smart_route_apps_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('mark all changes only the draft on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const vk = 'com.vkontakte.android';
    const ok = 'ru.ok.android';
    const legacy = 'ru.sberbankmobile';
    const max = 'ru.oneme.app';
    const bank = 'ru.bspb';
    var returned = false;
    Set<String>? saved;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.25)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                saved = await showDialog<Set<String>>(
                  context: context,
                  builder: (_) => const SmartRouteAppsDialog(
                    snapshot: SmartRouteAppsSnapshot(
                      candidates: [
                        SmartRouteAppCandidate(
                          vk,
                          'ВКонтакте',
                          SmartRouteAppAvailability.installed,
                        ),
                        SmartRouteAppCandidate(
                          ok,
                          'Одноклассники',
                          SmartRouteAppAvailability.missing,
                        ),
                        SmartRouteAppCandidate(
                          max,
                          'MAX',
                          SmartRouteAppAvailability.missing,
                        ),
                        SmartRouteAppCandidate(
                          bank,
                          'БСПБ',
                          SmartRouteAppAvailability.installed,
                        ),
                      ],
                      selected: {bank},
                      supported: true,
                    ),
                    builtInPackages: {vk, ok, legacy},
                    smartRouteEnabled: true,
                    managedProfile: true,
                    vpnActive: true,
                    russian: true,
                  ),
                );
                returned = true;
              },
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();

    CheckboxListTile row(String id) =>
        tester.widget(find.byKey(ValueKey('smart-route-app-$id')));
    final markAll = find.byKey(const ValueKey('smart-route-select-all'));
    final save = find.widgetWithText(FilledButton, 'Сохранить');
    for (final builtIn in [vk, ok]) {
      expect(row(builtIn).value, isTrue);
      expect(row(builtIn).onChanged, isNull);
    }
    expect(row(bank).value, isTrue);
    expect(row(max).value, isFalse);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.ensureVisible(markAll);
    await tester.tap(markAll);
    await tester.pumpAndSettle();
    expect(returned, isFalse);
    expect(row(bank).value, isTrue);
    expect(row(max).value, isTrue);
    expect(find.text('Выбрано: 4 из 4'), findsOneWidget);
    expect(find.text('Не установлено · не применяется'), findsNWidgets(2));
    expect(find.text('Сохранить и переподключить'), findsNothing);

    final builtInHeader = find.text('Встроенные исключения (1)');
    await tester.ensureVisible(builtInHeader);
    await tester.tap(builtInHeader);
    await tester.pumpAndSettle();
    final builtInRow = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, legacy),
    );
    expect(builtInRow.value, isTrue);
    expect(builtInRow.onChanged, isNull);
    expect(find.text('ВКонтакте'), findsOneWidget);
    expect(find.text('Одноклассники'), findsOneWidget);

    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(saved, unorderedEquals({bank, max}));
    expect(tester.takeException(), isNull);
  });
}
