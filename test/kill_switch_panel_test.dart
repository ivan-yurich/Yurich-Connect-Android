import 'package:aurum_vpn/src/screens/kill_switch_panel.dart';
import 'package:aurum_vpn/src/services/kill_switch_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> show(WidgetTester tester, KillSwitchState state) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KillSwitchPanel(
              state: state,
              russian: true,
              busy: false,
              onSettings: () {},
              onRefresh: () {},
              onApply: () {},
            ),
          ),
        ),
      );

  testWidgets('unknown runtime offers no automatic apply action', (
    tester,
  ) async {
    await show(
      tester,
      const KillSwitchState(known: true, alwaysOn: true, lockdown: true),
    );
    expect(
      find.text('Android блокирует обход; состояние TUN уточняется'),
      findsOneWidget,
    );
    expect(find.text('Применить строгие маршруты'), findsNothing);
    expect(find.text('Включён: Android + строгий TUN'), findsNothing);
  });

  testWidgets('complete strict runtime is visibly confirmed', (tester) async {
    await show(
      tester,
      const KillSwitchState(
        known: true,
        runtimeKnown: true,
        alwaysOn: true,
        lockdown: true,
        strictRuntime: true,
        vpnActive: true,
      ),
    );
    expect(find.text('Включён: Android + строгий TUN'), findsOneWidget);
    expect(find.text('Применить строгие маршруты'), findsNothing);
  });

  testWidgets('persisted intent with unknown OS state never looks enabled', (
    tester,
  ) async {
    await show(tester, const KillSwitchState(requested: true));
    expect(find.text('Состояние не подтверждено'), findsOneWidget);
    expect(
      find.text(
        'Запрос строгого режима сохранён; это не подтверждение защиты.',
      ),
      findsOneWidget,
    );
    expect(find.text('Включён: Android + строгий TUN'), findsNothing);
    expect(find.text('Обычные маршруты'), findsNothing);
  });
}
