import 'package:aurum_vpn/src/models/vpn_profile.dart';
import 'package:aurum_vpn/src/screens/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final locale in ['en', 'ru']) {
    final english = locale == 'en';
    final labels = english ? HomeProfileLabels.en : HomeProfileLabels.ru;

    test(
      'unsupported profile messages distinguish XHTTP and raw config ($locale)',
      () {
        expect(
          labels.unsupportedProtocol(VpnProfileKind.vlessXhttp),
          startsWith(
            english
                ? 'The bundled Xray core could not start this VLESS XHTTP profile.'
                : 'Встроенное Xray-ядро не смогло запустить этот VLESS XHTTP профиль.',
          ),
        );
        expect(
          labels.unsupportedProtocol(VpnProfileKind.singBoxConfig),
          startsWith(
            english
                ? 'Sing-box is not enabled in this Android build.'
                : 'Sing-box отключён в этой Android-сборке.',
          ),
        );
      },
    );

    test('missing expiry is unknown rather than expired ($locale)', () {
      final now = DateTime.utc(2026, 11, 16, 12);
      expect(
        labels.subscriptionStatus(null, now: now),
        english ? 'Not provided' : 'Срок не указан',
      );
      expect(
        labels.subscriptionStatus(
          now.subtract(const Duration(seconds: 1)),
          now: now,
        ),
        english ? 'Expired' : 'Истекла',
      );
    });

    test(
      'known expiry formatting keeps the hours and days boundary ($locale)',
      () {
        final now = DateTime.utc(2026, 11, 16, 12);
        for (final (remaining, expected) in [
          (Duration.zero, english ? '1 h left' : 'Осталось 1 ч'),
          (
            const Duration(hours: 23, minutes: 59),
            english ? '23 h left' : 'Осталось 23 ч',
          ),
          (const Duration(days: 1), english ? '1 d left' : 'Осталось 1 дн.'),
          (const Duration(hours: 25), english ? '2 d left' : 'Осталось 2 дн.'),
        ]) {
          expect(
            labels.subscriptionStatus(now.add(remaining), now: now),
            expected,
          );
        }
      },
    );
  }

  testWidgets(
    'absent flag uses a neutral globe and a known marker is preserved',
    (tester) async {
      Future<void> show(String? flag) => tester.pumpWidget(
        MaterialApp(home: Center(child: MobileProfileFlag(flag))),
      );

      await show(null);
      expect(find.byIcon(Icons.public_rounded), findsOneWidget);
      expect(find.text('🇵🇱'), findsNothing);
      await show('🇵🇱');
      expect(find.byIcon(Icons.public_rounded), findsNothing);
      expect(find.text('🇵🇱'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
