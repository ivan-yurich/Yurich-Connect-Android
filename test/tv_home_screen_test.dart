import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurum_vpn/src/models/connection_status.dart';
import 'package:aurum_vpn/src/models/connection_ui_state.dart';
import 'package:aurum_vpn/src/screens/tv_home_screen.dart';
import 'package:aurum_vpn/src/theme/yurich_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _writeAssets = bool.fromEnvironment('WRITE_TV_ASSETS');
const _qaDirectory = 'build/qa/android-tv-20261003';

List<TvProfileItem> _profiles([int count = 20]) => List.generate(
  count,
  (index) => TvProfileItem(
    id: 'p$index',
    name: index == 1
        ? 'Очень длинное название сервера Finland / Poland 2 / Yurich Connect'
        : 'Finland ${index + 1}',
    protocol: ['Reality', 'Hysteria2', 'NaiveProxy', 'XHTTP TLS'][index % 4],
    country: 'FI',
    latency: '${80 + index} ms',
    group: [
      TvProtocolGroup.vless,
      TvProtocolGroup.hysteria,
      TvProtocolGroup.naive,
      TvProtocolGroup.xhttp,
    ][index % 4],
    selected: index == 0,
    active: index == 0,
  ),
);

Future<void> _viewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

TvHomeScreen _screen({
  List<TvProfileItem>? profiles,
  bool busy = false,
  bool connected = true,
  bool russian = true,
  ConnectionStatus status = ConnectionStatus.connected,
  ConnectionUiState? connection,
  VoidCallback? onToggle,
  ValueChanged<String>? onSelect,
  VoidCallback? onImport,
  ValueChanged<bool>? onSmartRoute,
  ValueChanged<bool>? onAutoDns,
  ValueChanged<bool>? onLogsVisible,
}) => TvHomeScreen(
  russian: russian,
  connection:
      connection ??
      ConnectionUiState(
        status: status,
        uploadSpeed: '320 KB/s',
        downloadSpeed: '4.2 MB/s',
        totalTraffic: '1.3 GB',
        profileName: 'Finland',
        protocolDisplayName: 'Reality',
      ),
  connected: connected,
  busy: busy,
  message: 'Соединение проверено',
  uptime: '02:14:36',
  version: '1.0.128-tv.1',
  smartRoute: true,
  autoDns: true,
  refreshing: false,
  profiles: profiles ?? _profiles(),
  logs: List.generate(
    80,
    (index) => '12:34:${index % 60}  VPN health check / sample $index',
  ),
  onToggle: onToggle ?? () {},
  onSelect: onSelect ?? (_) {},
  onImport: onImport ?? () {},
  onRefresh: () {},
  onSmartRoute: onSmartRoute ?? (_) {},
  onAutoDns: onAutoDns ?? (_) {},
  onLogsVisible: onLogsVisible ?? (_) {},
  onLanguage: () {},
  onReleases: () {},
  onPrivacy: () {},
);

Widget _app(Widget child) =>
    MaterialApp(theme: YurichTheme.dark(), home: child);

Future<void> _capture(WidgetTester tester, GlobalKey key, String path) async {
  if (!_writeAssets) return;
  await tester.runAsync(
    () => precacheImage(
      const AssetImage('assets/images/app_icon.png'),
      key.currentContext!,
    ),
  );
  await tester.pumpAndSettle();
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    if (!_writeAssets) return;
    var ancestor = File(Platform.resolvedExecutable).parent;
    Directory? fonts;
    for (var i = 0; i < 10; i++) {
      final candidate = Directory(
        '${ancestor.path}/bin/cache/artifacts/material_fonts',
      );
      if (candidate.existsSync()) {
        fonts = candidate;
        break;
      }
      ancestor = ancestor.parent;
    }
    if (fonts == null) {
      throw StateError(
        'Flutter SDK material fonts not found; do not export the Ahem test font.',
      );
    }
    for (final entry in {
      'Roboto': ['roboto-regular.ttf', 'roboto-medium.ttf', 'roboto-bold.ttf'],
      'MaterialIcons': ['materialicons-regular.otf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final file in entry.value) {
        loader.addFont(
          File(
            '${fonts.path}/$file',
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      }
      await loader.load();
    }
  });

  for (final size in [
    const Size(960, 540),
    const Size(1280, 720),
    const Size(1920, 1080),
    const Size(640, 360),
  ]) {
    testWidgets('TV layout fits ${size.width} x ${size.height}', (
      tester,
    ) async {
      await _viewport(tester, size);
      final captureKey = GlobalKey();
      await tester.pumpWidget(
        _app(RepaintBoundary(key: captureKey, child: _screen())),
      );
      await tester.pumpAndSettle();
      expect(find.text('Yurich Connect TV'), findsOneWidget);
      expect(find.text('Отключить'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(
        tester,
        captureKey,
        '$_qaDirectory/tv-${size.width.toInt()}x${size.height.toInt()}.png',
      );
      await tester.tap(find.byKey(const ValueKey('tv-settings-tab')));
      await tester.pumpAndSettle();
      expect(find.text('Smart Route'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(
        tester,
        captureKey,
        '$_qaDirectory/settings-${size.width.toInt()}x${size.height.toInt()}.png',
      );
    });
  }

  testWidgets(
    'remote select activates Connect, focus survives traffic rebuild',
    (tester) async {
      await _viewport(tester, const Size(960, 540));
      var toggles = 0;
      await tester.pumpWidget(_app(_screen(onToggle: () => toggles++)));
      await tester.pumpAndSettle();
      final initialFocus = FocusManager.instance.primaryFocus;
      expect(initialFocus, isNotNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(toggles, 1);
      await tester.pumpWidget(_app(_screen(onToggle: () => toggles++)));
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, same(initialFocus));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(toggles, 2);
    },
  );

  testWidgets('empty app initially focuses import; busy app cannot connect', (
    tester,
  ) async {
    await _viewport(tester, const Size(960, 540));
    var imports = 0;
    var toggles = 0;
    await tester.pumpWidget(
      _app(
        _screen(
          profiles: [],
          onImport: () => imports++,
          onToggle: () => toggles++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(imports, 1);
    expect(toggles, 0);
    await tester.pumpWidget(
      _app(_screen(busy: true, onToggle: () => toggles++)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tv-connect')));
    await tester.pumpAndSettle();
    expect(toggles, 0);
  });

  testWidgets('D-pad reaches all 1000 lazy profiles without a focus dead end', (
    tester,
  ) async {
    await _viewport(tester, const Size(960, 540));
    final selected = <String>[];
    await tester.pumpWidget(
      _app(_screen(profiles: _profiles(1000), onSelect: selected.add)),
    );
    await tester.pumpAndSettle();
    final first = tester.widget<TvAction>(
      find.byKey(const ValueKey('tv-profile-p0')),
    );
    first.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    for (var i = 0; i < 999; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(FocusManager.instance.primaryFocus!.debugLabel, 'tv-profile-p999');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(selected, ['p999']);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus!.debugLabel, 'tv-profile-p998');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'filter changes remove stale focus and show only matching protocols',
    (tester) async {
      await _viewport(tester, const Size(960, 540));
      await tester.pumpWidget(_app(_screen()));
      await tester.pumpAndSettle();
      tester
          .widget<TvAction>(find.byKey(const ValueKey('tv-profile-p0')))
          .focusNode!
          .requestFocus();
      await tester.pump();
      await tester.ensureVisible(find.text('XHTTP'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('XHTTP'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tv-profile-p0')), findsNothing);
      expect(find.byKey(const ValueKey('tv-profile-p3')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('remote crosses panes and activates a profile without taps', (
    tester,
  ) async {
    await _viewport(tester, const Size(960, 540));
    final selected = <String>[];
    await tester.pumpWidget(_app(_screen(onSelect: selected.add)));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus!.debugLabel,
      startsWith('tv-profile-'),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(selected, hasLength(1));
  });

  testWidgets('remote scrolls protocol filters into view', (tester) async {
    await _viewport(tester, const Size(640, 360));
    await tester.pumpWidget(_app(_screen()));
    await tester.pumpAndSettle();
    Focus.of(tester.element(find.text('Все'))).requestFocus();
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    expect(tester.getCenter(find.text('XHTTP')).dx, lessThan(640));
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tv-profile-p0')), findsNothing);
    expect(find.byKey(const ValueKey('tv-profile-p3')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('larger system text fits TV profile rows and controls', (
    tester,
  ) async {
    await _viewport(tester, const Size(960, 540));
    await tester.pumpWidget(
      _app(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(960, 540),
            textScaler: TextScaler.linear(1.5),
          ),
          child: _screen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('tv-settings-tab')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings call existing preferences; Back preserves VPN', (
    tester,
  ) async {
    await _viewport(tester, const Size(960, 540));
    final routes = <bool>[];
    final dns = <bool>[];
    var toggles = 0;
    await tester.pumpWidget(
      _app(
        _screen(
          onToggle: () => toggles++,
          onSmartRoute: routes.add,
          onAutoDns: dns.add,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tv-settings-tab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tv-smart-route')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tv-auto-dns')));
    await tester.pumpAndSettle();
    expect(routes, [false]);
    expect(dns, [false]);
    final context = tester.element(find.byType(TvHomeScreen));
    await Navigator.of(context).maybePop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tv-profile-list')), findsOneWidget);
    expect(toggles, 0);
  });

  testWidgets('logs scroll with remote and unsubscribe when Back returns', (
    tester,
  ) async {
    await _viewport(tester, const Size(960, 540));
    final visibility = <bool>[];
    await tester.pumpWidget(_app(_screen(onLogsVisible: visibility.add)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tv-logs-tab')));
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(TvScrollableText),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scrollable.position.pixels, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(0));
    await Navigator.of(tester.element(find.byType(TvHomeScreen))).maybePop();
    await tester.pumpAndSettle();
    expect(visibility, [true, false]);
  });

  testWidgets('no false Connected label during native reconnect', (
    tester,
  ) async {
    await _viewport(tester, const Size(960, 540));
    await tester.pumpWidget(
      _app(_screen(status: ConnectionStatus.reconnecting)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Подключено'), findsNothing);
    expect(find.text('Переподключение'), findsOneWidget);
    await tester.pumpWidget(
      _app(_screen(status: ConnectionStatus.failed, russian: false)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Connection failed'), findsOneWidget);
  });

  testWidgets('disconnected TV shows the selected profile before connecting', (
    tester,
  ) async {
    await _viewport(tester, const Size(960, 540));
    await tester.pumpWidget(
      _app(
        _screen(connected: false, connection: ConnectionUiState.disconnected()),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('tv-selected-name'))).data,
      'Finland 1',
    );
    expect(find.text('Профиль не выбран'), findsNothing);
    expect(find.text('Отключено'), findsOneWidget);
    expect(find.text('Подключить'), findsOneWidget);
  });

  testWidgets('TV import has no camera and returns link without modifying it', (
    tester,
  ) async {
    await _viewport(tester, const Size(960, 540));
    String? result;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showTvImportDialog(context, russian: true);
            },
            child: const Text('Open import'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open import'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.qr_code_scanner), findsNothing);
    const input = 'https://example.invalid/s/test-only/links.txt';
    await tester.enterText(
      find.byKey(const ValueKey('tv-import-input')),
      input,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tv-import-submit')));
    await tester.pumpAndSettle();
    expect(result, input);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Back cancels import; clipboard is only pasted after user action',
    (tester) async {
      await _viewport(tester, const Size(960, 540));
      final binding = TestDefaultBinaryMessengerBinding.instance;
      var reads = 0;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            reads++;
            return {'text': 'vless://test@host.invalid:443'};
          }
          return null;
        },
      );
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      String? result = 'not-closed';
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showTvImportDialog(context, russian: true);
              },
              child: const Text('Open import'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open import'));
      await tester.pumpAndSettle();
      expect(reads, 0);
      await tester.tap(find.byKey(const ValueKey('tv-import-paste')));
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(find.text('vless://test@host.invalid:443'), findsOneWidget);
      await Navigator.of(tester.element(find.byType(TextField))).maybePop();
      await tester.pumpAndSettle();
      expect(result, isNull);
    },
  );

  testWidgets(
    'onscreen keyboard does not collapse the TV screen during import',
    (tester) async {
      await _viewport(tester, const Size(960, 540));
      addTearDown(tester.view.resetViewInsets);
      String? result;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => _screen(
              onImport: () async {
                result = await showTvImportDialog(context, russian: true);
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('tv-import')));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.enterText(
        find.byKey(const ValueKey('tv-import-input')),
        'https://example.invalid/links.txt',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(result, 'https://example.invalid/links.txt');
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('launcher banner is 320 x 180 with visible product name', (
    tester,
  ) async {
    await _viewport(tester, const Size(320, 180));
    final captureKey = GlobalKey();
    await tester.pumpWidget(
      _app(RepaintBoundary(key: captureKey, child: const TvLauncherBanner())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Yurich Connect'), findsOneWidget);
    expect(find.text('TV'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(
      tester,
      captureKey,
      'android/app/src/tv/res/drawable-xhdpi/tv_banner.png',
    );
  });
}
