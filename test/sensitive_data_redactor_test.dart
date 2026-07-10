import 'package:aurum_vpn/src/services/sensitive_data_redactor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
        'failed https://user:pass@plus-dns.tech/s/'
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
}
