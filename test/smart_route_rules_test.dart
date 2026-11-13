import 'package:aurum_vpn/src/services/smart_route_rules.dart';
import 'package:flutter_test/flutter_test.dart';

bool _matches(SmartRouteDomainRules rules, String host) {
  return rules.matchesHost(host);
}

void main() {
  test('domain policy normalizes FQDNs but never URLs or deceptive names', () {
    for (final name in [' YANDEX.RU. ', 'api.yandex.ru']) {
      expect(SmartRouteRules.domainOutbound(name), 'direct');
      expect(SmartRouteRules.domainOutbound(name, enabled: false), 'proxy');
    }
    for (final name in [
      'https://yandex.ru',
      'yandex.ru:443',
      'yandex.ru.evil.test',
      'notyandex.ru',
      '*.yandex.ru',
      'yandex..ru',
      'яndex.ru',
      '192.0.2.1',
      'google.ru',
      'unknown.ru',
    ]) {
      expect(SmartRouteRules.domainOutbound(name), 'proxy', reason: name);
    }
  });

  test(
    'compiler rejects malformed future exceptions before building native config',
    () {
      for (final domain in [
        'https://service.example',
        'service.example:443',
        '*.service.example',
        'service..example',
        '-service.example',
        'service-.example',
        '192.0.2.1',
        '${'a' * 64}.example',
        'service.example/path',
        'service.example?route=direct',
      ]) {
        expect(
          () => SmartRouteDomainRules.compile(
            domains: [domain],
            domainSuffixes: const [],
          ),
          throwsArgumentError,
          reason: domain,
        );
      }
    },
  );
  test('unknown country-code domains do not enter the direct allowlist', () {
    final rules = SmartRouteRules.directDomainRules;
    for (final host in [
      'unknown.ru',
      'unknown.su',
      'unknown.xn--p1ai',
      'unknown.рф',
    ]) {
      expect(_matches(rules, host), isFalse, reason: host);
    }
    expect(
      rules.domainSuffixes,
      isNot(anyOf(contains('ru'), contains('su'), contains('рф'))),
    );
  });

  test('public search hosts are direct without exempting unknown sites', () {
    for (final host in [
      'ya.ru',
      'mail.ru',
      'r0.ru',
      'nova.rambler.ru',
      'images.rambler.ru',
    ]) {
      expect(SmartRouteRules.domainOutbound(host), 'direct', reason: host);
    }
    for (final host in [
      'unknown.rambler.ru',
      'sub.r0.ru',
      'r0.ru.example.com',
      'tenant.website.yandexcloud.net',
      'tenant.storage.yandexcloud.net',
      'unknown.ru',
    ]) {
      expect(SmartRouteRules.domainOutbound(host), 'proxy', reason: host);
    }
  });

  test('known service roots and subdomains remain direct', () {
    for (final domain in SmartRouteRules.ruDirectDomains) {
      expect(
        _matches(SmartRouteRules.directDomainRules, domain),
        isTrue,
        reason: domain,
      );
    }
    for (final domain in SmartRouteRules.ruDirectDomainSuffixes) {
      expect(
        _matches(SmartRouteRules.directDomainRules, domain),
        isTrue,
        reason: domain,
      );
      expect(
        _matches(SmartRouteRules.directDomainRules, 'cdn.$domain'),
        isTrue,
        reason: domain,
      );
    }
  });

  test('service-looking names do not match outside a DNS label boundary', () {
    for (final host in [
      'notyandex.ru',
      'yandex.ru.attacker.test',
      'sberbank.ru.attacker.test',
      'notgosuslugi.ru',
    ]) {
      expect(
        _matches(SmartRouteRules.directDomainRules, host),
        isFalse,
        reason: host,
      );
    }
  });

  test('compaction preserves every global proxy domain and suffix', () {
    for (final domain in SmartRouteRules.globalProxyDomains) {
      expect(
        _matches(SmartRouteRules.proxyDomainRules, domain),
        isTrue,
        reason: domain,
      );
    }
    for (final domain in SmartRouteRules.globalProxyDomainSuffixes) {
      expect(
        _matches(SmartRouteRules.proxyDomainRules, 'cdn.$domain'),
        isTrue,
        reason: domain,
      );
    }
  });

  test(
    'compiles duplicate and covered entries only once without broadening',
    () {
      final rules = SmartRouteDomainRules.compile(
        domains: [
          'API.example.com',
          'api.example.com.',
          'only.test',
          'only.test',
        ],
        domainSuffixes: [
          'Example.COM',
          'example.com.',
          'api.example.com',
          'ample.com',
        ],
      );
      expect(rules.domains, ['only.test']);
      expect(rules.domainSuffixes, ['ample.com', 'example.com']);
      expect(rules.xrayDomains, [
        'full:only.test',
        'domain:ample.com',
        'domain:example.com',
      ]);
      expect(_matches(rules, 'notexample.com'), isFalse);
      expect(_matches(rules, 'sub.only.test'), isFalse);
    },
  );

  test('country-code or empty rules cannot be introduced by the compiler', () {
    for (final suffix in ['ru', 'su', 'рф', 'xn--p1ai', '', '.example.com']) {
      expect(
        () => SmartRouteDomainRules.compile(
          domains: const [],
          domainSuffixes: [suffix],
        ),
        throwsArgumentError,
        reason: suffix,
      );
    }
  });

  test('cached route and package lists are immutable and shared', () {
    final domains = SmartRouteRules.proxyDomainRules;
    expect(identical(domains, SmartRouteRules.proxyDomainRules), isTrue);
    expect(
      () => domains.domainSuffixes.add('example.com'),
      throwsUnsupportedError,
    );
    expect(() => domains.domains.add('example.com'), throwsUnsupportedError);
    expect(() => domains.xrayDomains.clear(), throwsUnsupportedError);
    final packages = SmartRouteRules.ruBypassPackages(const []);
    expect(
      identical(
        packages,
        SmartRouteRules.ruBypassPackages(const ['ru.unknown']),
      ),
      isTrue,
    );
    expect(() => packages.add('com.android.chrome'), throwsUnsupportedError);
    expect(packages, isNot(contains('com.android.chrome')));
    expect(packages, isNot(contains('ru.unknown')));
  });
}
