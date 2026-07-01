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
  });
}
