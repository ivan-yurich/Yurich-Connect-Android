import 'dart:async';

import 'package:aurum_vpn/src/screens/qr_scan_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

void main() {
  testWidgets(
    'scanner ignores empty frames and returns only the first usable value',
    (tester) async {
      final previous = MobileScannerPlatform.instance;
      final scanner = _FakeScanner();
      MobileScannerPlatform.instance = scanner;
      addTearDown(() async {
        MobileScannerPlatform.instance = previous;
        await scanner.frames.close();
      });
      final results = <String?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: TextButton(
                  onPressed: () async => results.add(
                    await Navigator.of(context).push(
                      MaterialPageRoute<String>(
                        builder: (_) => const QrScanScreen(),
                      ),
                    ),
                  ),
                  child: const Text('Open scan'),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Open scan'));
      await tester.pumpAndSettle();
      expect(find.text('Сканировать QR'), findsOneWidget);
      expect(scanner.starts, 1);
      scanner.frames.add(
        const BarcodeCapture(
          barcodes: [
            Barcode(),
            Barcode(rawValue: '  '),
          ],
        ),
      );
      await tester.pump();
      expect(results, isEmpty);
      expect(find.byType(QrScanScreen), findsOneWidget);

      scanner.frames.add(
        const BarcodeCapture(
          barcodes: [
            Barcode(rawValue: ' '),
            Barcode(rawValue: 'https://first.example.invalid/sub'),
            Barcode(rawValue: 'https://other.example.invalid/sub'),
          ],
        ),
      );
      scanner.frames.add(
        const BarcodeCapture(
          barcodes: [Barcode(rawValue: 'https://late.example.invalid/sub')],
        ),
      );
      await tester.pumpAndSettle();
      expect(results, ['https://first.example.invalid/sub']);
      expect(find.text('Open scan'), findsOneWidget);
      expect(find.byType(QrScanScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

class _FakeScanner extends MobileScannerPlatform {
  final frames = StreamController<BarcodeCapture?>.broadcast();
  int starts = 0;

  @override
  Stream<BarcodeCapture?> get barcodesStream => frames.stream;

  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();

  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();

  @override
  Widget buildCameraView() => const SizedBox.expand();

  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async {
    starts++;
    return const MobileScannerViewAttributes(
      cameraDirection: CameraFacing.back,
      currentTorchMode: TorchState.unavailable,
      size: Size(640, 480),
    );
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}
