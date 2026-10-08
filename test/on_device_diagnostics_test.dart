import 'package:aurum_vpn/src/screens/diagnostics_panel.dart';
import 'package:aurum_vpn/src/services/on_device_diagnostics.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  var active = false;
  var available = false;
  var fail = false;
  var exportResult = true;

  setUp(() {
    active = false;
    available = false;
    fail = false;
    exportResult = true;
    calls.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      OnDeviceDiagnosticsService.channel,
      (call) async {
        calls.add(call);
        if (fail) throw PlatformException(code: 'unavailable');
        if (call.method == 'recordError') return null;
        if (call.method == 'export') return exportResult;
        if (call.method == 'start') {
          active = true;
          available = true;
        }
        if (call.method == 'stop') active = false;
        return {
          'active': active,
          'available': available,
          'startedAtMs': DateTime(2026, 10, 2, 12, 30).millisecondsSinceEpoch,
          'endsAtMs': DateTime(2026, 10, 9, 12, 30).millisecondsSinceEpoch,
          'endedAtMs': !active && available
              ? DateTime(2026, 10, 3, 12, 30).millisecondsSinceEpoch
              : 0,
          'events': 12,
          'rotatedEvents': 0,
        };
      },
    );
  });

  tearDown(
    () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
      OnDeviceDiagnosticsService.channel,
      null,
    ),
  );

  test('malformed optional metadata does not become active', () {
    final run = DiagnosticRun.fromMap({
      'active': 'true',
      'available': 1,
      'endsAtMs': 'not-a-date',
      'events': false,
    });
    expect(run.active, isFalse);
    expect(run.available, isFalse);
    expect(run.endsAt, isNull);
    expect(run.events, 0);
  });

  test('start and stop preserve availability of the report', () async {
    final service = OnDeviceDiagnosticsService();
    expect((await service.status()).available, isFalse);
    expect((await service.start()).active, isTrue);
    final stopped = await service.stop();
    expect(stopped.active, isFalse);
    expect(stopped.available, isTrue);
    expect(stopped.events, 12);
    expect(stopped.stoppedEarly, isTrue);
  });

  test('deadline completion is distinct from early stop', () {
    final run = DiagnosticRun.fromMap({
      'endedAtMs': 604801000,
      'endsAtMs': 604801000,
    });
    expect(run.stoppedEarly, isFalse);
    expect(
      DiagnosticRun.fromMap({'endsAtMs': 8640000000000001}).endsAt,
      isNull,
    );
  });

  test('only error categories cross the native boundary', () async {
    await OnDeviceDiagnosticsService.recordError('https://private/token');
    expect(calls, isEmpty);
    await OnDeviceDiagnosticsService.recordError('uncaught');
    expect(calls.single.arguments, {'type': 'uncaught'});
  });

  test(
    'error recording cannot throw or recursively report channel failure',
    () async {
      fail = true;
      await OnDeviceDiagnosticsService.recordError('uncaught');
      expect(calls.length, 1);
    },
  );

  Future<void> showPanel(WidgetTester tester, {bool russian = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DiagnosticsPanel(russian: russian)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'recording is opt-in and consent cancellation does not start it',
    (tester) async {
      await showPanel(tester);
      expect(find.text('Не запущена'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.textContaining('Пароли, подписки'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'start'), isEmpty);
    },
  );

  testWidgets('consent starts the seven day run and stop retains report', (
    tester,
  ) async {
    await showPanel(tester);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Начать'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.textContaining('До '), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('Остановлена досрочно'), findsOneWidget);
    expect(find.textContaining('Начало:'), findsOneWidget);
    expect(find.text('Событий: 12'), findsOneWidget);
    expect(calls.where((c) => c.method == 'stop').length, 1);
  });

  testWidgets('export cancellation is not reported as a saved file', (
    tester,
  ) async {
    available = true;
    exportResult = false;
    await showPanel(tester);
    await tester.tap(find.byTooltip('Экспортировать ZIP'));
    await tester.pumpAndSettle();
    expect(find.text('Отчёт сохранён'), findsNothing);
    expect(calls.where((c) => c.method == 'export').length, 1);
  });

  testWidgets('completed report warns before a new current run', (
    tester,
  ) async {
    available = true;
    await showPanel(tester);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Сначала экспортируйте предыдущий'),
      findsOneWidget,
    );
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
  });

  testWidgets('narrow screen and large text do not overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    active = true;
    available = true;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: const Scaffold(body: DiagnosticsPanel(russian: true)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('english labels are localized', (tester) async {
    await showPanel(tester, russian: false);
    expect(find.text('7-day diagnostics'), findsOneWidget);
    expect(find.byTooltip('Export ZIP'), findsOneWidget);
  });

  testWidgets('failed status read is not presented as a never-started run', (
    tester,
  ) async {
    fail = true;
    await showPanel(tester);
    expect(find.text('Не запущена'), findsNothing);
    expect(find.text('Диагностика недоступна'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    fail = false;
    available = true;
    await tester.tap(find.byTooltip('Повторить проверку'));
    await tester.pumpAndSettle();
    expect(find.text('Остановлена досрочно'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
  });
}
