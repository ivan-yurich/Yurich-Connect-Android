import 'package:aurum_vpn/src/services/sensitive_data_redactor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final scheme in ['NAIVE', 'naive+https']) {
    test('masks both Naive credentials in $scheme links', () {
      const user = 'fixture-user%40example';
      const password = 'fixture%3Apassword%40value';
      const destination = 'relay.example.invalid:2443/fixture';
      final redacted = SensitiveDataRedactor.redact(
        'connecting $scheme://$user:$password@$destination',
      );

      expect(redacted, 'connecting $scheme://***:***@$destination');
      expect(redacted, isNot(contains(user)));
      expect(redacted, isNot(contains(password)));
      expect(SensitiveDataRedactor.redact(redacted), redacted);
    });
  }

  test('redacts VPN credentials and JSON secrets', () {
    const input =
        'vless://uuid-secret@example.com:443 '
        'hy2://password@example.com:443 '
        '{"password":"secret","public_key":"key"}';

    final redacted = SensitiveDataRedactor.redact(input);

    expect(redacted, isNot(contains('uuid-secret')));
    expect(redacted, isNot(contains('password@example')));
    expect(redacted, isNot(contains('"secret"')));
    expect(redacted, isNot(contains('"key"')));
  });

  test('redacts subscription path, query token and URL credentials', () {
    const input =
        'failed https://user:pass@f1-fixture.example.test/s/'
        '0123456789abcdef0123456789abcdef0123456789abcdef/xhttp.txt'
        '?token=query-secret&client=android.';

    final redacted = SensitiveDataRedactor.redact(input);

    expect(redacted, contains('/s/***/xhttp.txt'));
    expect(redacted, contains('token=%2A%2A%2A'));
    expect(redacted, contains('client=android'));
    expect(redacted, isNot(contains('query-secret')));
    expect(redacted, isNot(contains('user:pass')));
  });

  test('redacts bearer tokens', () {
    expect(
      SensitiveDataRedactor.redact('Authorization: Bearer abc.def.ghi'),
      'Authorization: Bearer ***',
    );
  });

  test('still redacts credentials from retired PingTunnel links', () {
    final redacted = SensitiveDataRedactor.redact(
      'pingtunnel://legacy-user:legacy-secret@example.com:443',
    );
    expect(redacted, isNot(contains('legacy-user')));
    expect(redacted, isNot(contains('legacy-secret')));
  });
}
