import 'package:aurum_vpn/src/services/sing_box_log_filter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SingBoxLogFilter', () {
    test('filters noisy Android router and process lookup logs', () {
      expect(
        SingBoxLogFilter.isDiagnosticNoise(
          'INFO[0031] router: found package name: com.google.android.gm',
        ),
        isTrue,
      );
      expect(
        SingBoxLogFilter.isDiagnosticNoise(
          'INFO[0033] router: found user id: 10230',
        ),
        isTrue,
      );
      expect(
        SingBoxLogFilter.isDiagnosticNoise(
          'INFO[0032] router: failed to search process: process not found',
        ),
        isTrue,
      );
    });

    test('filters verbose XTLS trace frames from diagnostic reports', () {
      expect(
        SingBoxLogFilter.isDiagnosticNoise(
          'TRACE[0067] outbound/vless[proxy]: Xtls Unpadding new block 5 2840 padding 107 0',
        ),
        isTrue,
      );
      expect(
        SingBoxLogFilter.isDiagnosticNoise(
          'TRACE[0068] outbound/vless[proxy]: XtlsPadding 126 1263 0',
        ),
        isTrue,
      );
      expect(
        SingBoxLogFilter.isDiagnosticNoise(
          'TRACE[0068] outbound/vless[proxy]: XtlsFilterTls found tls 1.2! 1163',
        ),
        isTrue,
      );
    });

    test('keeps useful connection and error logs', () {
      expect(
        SingBoxLogFilter.isDiagnosticNoise(
          'INFO[0067] outbound/vless[proxy]: outbound connection to example.com:443',
        ),
        isFalse,
      );
      expect(
        SingBoxLogFilter.isDiagnosticNoise(
          'ERROR[0005] dns: exchange failed for mtalk.google.com. IN A',
        ),
        isFalse,
      );
    });

    test('keeps TLS and DNS failures in order in a mixed diagnostic batch', () {
      const failures = [
        'ERROR outbound/vless[proxy]: TLS handshake failed: certificate expired',
        'ERROR dns: exchange failed for endpoint.example.invalid',
      ];
      final batch = [
        'INFO router: found package name: org.example.fixture',
        failures[0],
        'TRACE outbound/vless[proxy]: XtlsPadding 1 2 3',
        failures[1],
        'INFO router: found user id: 12345',
      ];

      expect(
        batch.where((line) => !SingBoxLogFilter.isDiagnosticNoise(line)),
        failures,
      );
    });

    test('does not hide failures that resemble router or XTLS noise', () {
      for (final line in [
        'ERROR router: failed to search process: permission denied',
        'ERROR outbound/vless[backup]: XtlsPadding failed',
      ]) {
        expect(SingBoxLogFilter.isDiagnosticNoise(line), isFalse, reason: line);
      }
    });
  });
}
