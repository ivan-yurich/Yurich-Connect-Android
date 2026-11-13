class SmartRouteRules {
  const SmartRouteRules._();

  static const globalProxyDomains = [
    'chat.openai.com',
    'api.openai.com',
    'auth.openai.com',
    'chatgpt.com',
    'chat.com',
    'claude.ai',
    'api.anthropic.com',
    'console.anthropic.com',
    'perplexity.ai',
    'www.perplexity.ai',
    'poe.com',
    'gemini.google.com',
    'aistudio.google.com',
    'copilot.microsoft.com',
    'www.bing.com',
    'api.bing.microsoft.com',
    'accounts.google.com',
    'oauth2.googleapis.com',
    'clients6.google.com',
    'play.googleapis.com',
    'android.clients.google.com',
    'mtalk.google.com',
    'fcm.googleapis.com',
    'firebaseinstallations.googleapis.com',
    'firebaseremoteconfig.googleapis.com',
    'generativelanguage.googleapis.com',
    'youtubei.googleapis.com',
    'youtube.googleapis.com',
    'www.youtube.com',
    'm.youtube.com',
    'i.ytimg.com',
    'telegram.org',
    't.me',
    'web.telegram.org',
    'api.telegram.org',
    'updates.tdesktop.com',
    'www.instagram.com',
    'graph.instagram.com',
    'cdninstagram.com',
    'x.com',
    'api.x.com',
    'twitter.com',
    'api.twitter.com',
    'discord.com',
    'cdn.discordapp.com',
  ];

  static const globalProxyDomainSuffixes = [
    'chat.com',
    'chatgpt.com',
    'openai.com',
    'oaistatic.com',
    'oaiusercontent.com',
    'auth0.openai.com',
    'anthropic.com',
    'claude.ai',
    'perplexity.ai',
    'poe.com',
    'bing.com',
    'bingapis.com',
    'microsoft.com',
    'microsoftonline.com',
    'live.com',
    'office.com',
    'g.co',
    'goo.gle',
    'google.com',
    'google.ru',
    'googleapis.com',
    'gstatic.com',
    'gvt1.com',
    'ggpht.com',
    'googleusercontent.com',
    'googleapis.cn',
    'firebaseio.com',
    'firebaseapp.com',
    'appspot.com',
    'generativelanguage.googleapis.com',
    'bard.google.com',
    'gemini.google.com',
    'youtube.com',
    'youtu.be',
    'ytimg.com',
    'googlevideo.com',
    'youtubei.googleapis.com',
    'telegram.org',
    'telegram.me',
    't.me',
    'tdesktop.com',
    'telegra.ph',
    'telegram-cdn.org',
    'telesco.pe',
    'instagram.com',
    'cdninstagram.com',
    'ig.me',
    'threads.net',
    'facebook.com',
    'fb.com',
    'fbcdn.net',
    'fbsbx.com',
    'meta.com',
    'messenger.com',
    'whatsapp.com',
    'whatsapp.net',
    'x.com',
    'twitter.com',
    'twimg.com',
    'tiktok.com',
    'tiktokcdn.com',
    'discord.com',
    'discord.gg',
    'discordapp.com',
    'discordapp.net',
    'discord.media',
    'github.com',
    'githubusercontent.com',
    'githubassets.com',
    'github.io',
    'netflix.com',
    'nflxvideo.net',
    'spotify.com',
    'spotifycdn.com',
    'reddit.com',
    'redd.it',
    'redditmedia.com',
    'snapchat.com',
    'sc-cdn.net',
  ];

  static const ruDirectPackageNames = [
    'ru.yandex.mail',
    'ru.yandex.disk',
    'ru.yandex.taxi',
    'ru.yandex.go',
    'ru.yandex.music',
    'ru.yandex.market',
    'ru.yandex.mobile.maps',
    'ru.vk.android',
    'com.vkontakte.android',
    'ru.vk.store',
    'ru.mail.mailapp',
    'ru.mail.cloud',
    'ru.ok.android',
    'ru.id.vk',
    'ru.sberbankmobile',
    'ru.sberbankmobile_alpha',
    'ru.sberbank.android',
    'ru.vtb24.mobilebanking.android',
    'ru.alfabank.mobile.android',
    'ru.tinkoff.mb',
    'ru.tinkoff.investing',
    'com.idamob.tinkoff.android',
    'ru.gazprombank.android.mobilebank.app',
    'ru.mkb.mobile',
    'ru.rosbank.android',
    'ru.pochtabank.mobile',
    'ru.rshb.dbo',
    'ru.openbank.mobile',
    'ru.raiffeisennews',
    'ru.yoomoney',
    'ru.mirpay',
    'ru.gosuslugi',
    'ru.mos',
    'ru.ozon.app.android',
    'ru.ozon.travel',
    'ru.wildberries',
    'com.wildberries.ru',
    'ru.wb.go',
    'com.avito.android',
    'ru.drom.android.app',
    'ru.cian.main',
    'ru.rutube.app',
    'ru.kinopoisk',
    'ru.more.play',
    'ru.ivi.client',
    'ru.okko.android',
    'ru.mts.client',
    'ru.beeline.services',
    'ru.megafon.mlk',
    'ru.tele2.mytele2',
  ];

  static const globalProxyPackageNames = [
    'com.openai.chatgpt',
    'ai.perplexity.app.android',
    'com.microsoft.copilot',
    'com.microsoft.bing',
    'com.microsoft.office.officehubrow',
    'com.microsoft.office.outlook',
    'com.microsoft.skydrive',
    'com.android.chrome',
    'com.chrome.beta',
    'com.chrome.dev',
    'com.brave.browser',
    'org.mozilla.firefox',
    'org.mozilla.firefox_beta',
    'com.opera.browser',
    'com.microsoft.emmx',
    'com.google.android.gm',
    'com.google.android.apps.bard',
    'com.google.android.apps.gemini',
    'com.google.android.gms',
    'com.google.android.gsf',
    'com.google.android.googlequicksearchbox',
    'com.google.android.apps.docs',
    'com.google.android.apps.photos',
    'com.google.android.apps.maps',
    'com.google.android.apps.translate',
    'com.google.android.apps.meetings',
    'com.google.android.apps.messaging',
    'com.google.android.apps.authenticator2',
    'com.google.android.apps.walletnfcrel',
    'com.google.android.apps.searchlite',
    'com.google.android.youtube',
    'com.google.android.youtube.tv',
    'com.google.android.apps.youtube.music',
    'com.google.android.apps.youtube.creator',
    'com.google.android.apps.youtube.kids',
    'app.revanced.android.youtube',
    'com.vanced.android.youtube',
    'org.telegram.messenger',
    'org.telegram.messenger.beta',
    'org.telegram.messenger.web',
    'org.telegram.plus',
    'org.thunderdog.challegram',
    'com.instagram.android',
    'com.instagram.barcelona',
    'com.facebook.katana',
    'com.facebook.lite',
    'com.facebook.orca',
    'com.facebook.mlite',
    'com.whatsapp',
    'com.whatsapp.w4b',
    'com.twitter.android',
    'com.twitter.android.lite',
    'com.x.android',
    'com.zhiliaoapp.musically',
    'com.zhiliaoapp.musically.go',
    'com.discord',
    'com.github.android',
    'com.netflix.mediaclient',
    'com.spotify.music',
    'com.reddit.frontpage',
    'com.snapchat.android',
  ];

  static const ruBypassDenyPackageNames = [
    ...globalProxyPackageNames,
    'ru.yandex.browser',
    'ru.yandex.searchplugin',
    'com.yandex.browser',
    'com.yandex.searchapp',
  ];

  static List<String> ruBypassPackages(Iterable<String> installedPackages) {
    // Deliberately use only the curated allowlist, never a package-name prefix
    // or a partial launcher-app inventory. Native Android ignores absent apps.
    return _ruBypassPackages;
  }

  static final _ruBypassPackages = _compileBypassPackages();

  static List<String> _compileBypassPackages() {
    final denied = ruBypassDenyPackageNames.toSet();
    final packages = <String>{...ruDirectPackageNames};
    packages.removeAll(denied);
    final sorted = packages.toList()..sort();
    return List<String>.unmodifiable(sorted);
  }

  static const ruDirectDomainSuffixes = [
    // A country-code suffix alone is not an allowlist of trusted services.
    'yandex.ru',
    'ya.ru',
    'mos.ru',
    'gov.ru',
    'gosuslugi.ru',
    'yandex.net',
    'yastatic.net',
    'yandex.st',
    'vk.com',
    'vkuser.net',
    'userapi.com',
    'vk-cdn.net',
    'mycdn.me',
    'mail.ru',
    'imgsmail.ru',
    'ok.ru',
    'odnoklassniki.ru',
    'sberbank.ru',
    'sber.ru',
    'vtb.ru',
    'alfabank.ru',
    'tinkoff.ru',
    'tbank.ru',
    'gazprombank.ru',
    'mkb.ru',
    'rosbank.ru',
    'pochtabank.ru',
    'rshb.ru',
    'open.ru',
    'raiffeisen.ru',
    'yoomoney.ru',
    'mironline.ru',
    'ozon.ru',
    'wildberries.ru',
    'wb.ru',
    'avito.ru',
    'drom.ru',
    'rutube.ru',
    'kinopoisk.ru',
    '2gis.ru',
    'mts.ru',
    'beeline.ru',
    'megafon.ru',
    'tele2.ru',
  ];

  static const ruDirectDomains = [
    'vk.com',
    'ok.ru',
    'mail.ru',
    'yandex.ru',
    'ya.ru',
    // Public search only. Other Rambler subdomains are not implicitly trusted.
    'r0.ru',
    'nova.rambler.ru',
    'images.rambler.ru',
    'sberbank.ru',
    'sber.ru',
    'vtb.ru',
    'alfabank.ru',
    'tinkoff.ru',
    'tbank.ru',
    'gazprombank.ru',
    'mkb.ru',
    'rosbank.ru',
    'pochtabank.ru',
    'rshb.ru',
    'open.ru',
    'raiffeisen.ru',
    'yoomoney.ru',
    'mironline.ru',
    'gosuslugi.ru',
    'mos.ru',
    'ozon.ru',
    'wildberries.ru',
    'wb.ru',
    'avito.ru',
    'drom.ru',
    'rutube.ru',
    'kinopoisk.ru',
    '2gis.ru',
  ];

  // Compile once per isolate, then share immutable lists across reconnects and
  // both VPN engines. Proxy rules always precede the direct allowlist.
  static final proxyDomainRules = SmartRouteDomainRules.compile(
    domains: globalProxyDomains,
    domainSuffixes: globalProxyDomainSuffixes,
  );

  static final directDomainRules = SmartRouteDomainRules.compile(
    domains: ruDirectDomains,
    domainSuffixes: ruDirectDomainSuffixes,
  );

  /// Domain policy only: Android per-app exclusions and private LAN IP rules
  /// are separate. An invalid/unknown name never becomes a direct exception.
  static String domainOutbound(String host, {bool enabled = true}) {
    if (!enabled || proxyDomainRules.matchesHost(host)) return 'proxy';
    return directDomainRules.matchesHost(host) ? 'direct' : 'proxy';
  }
}

/// A compact domain policy; removes only entries covered by the same route.
final class SmartRouteDomainRules {
  SmartRouteDomainRules._(List<String> domains, List<String> domainSuffixes)
    : domains = List.unmodifiable(domains),
      domainSuffixes = List.unmodifiable(domainSuffixes),
      _exactSet = Set.unmodifiable(domains),
      _suffixSet = Set.unmodifiable(domainSuffixes),
      xrayDomains = List.unmodifiable([
        for (final domain in domains) 'full:$domain',
        for (final suffix in domainSuffixes) 'domain:$suffix',
      ]);

  factory SmartRouteDomainRules.compile({
    required Iterable<String> domains,
    required Iterable<String> domainSuffixes,
  }) {
    final suffixes = domainSuffixes.map(_normalize).toSet();
    final exact = domains.map(_normalize).toSet();
    for (final name in {...suffixes, ...exact}) {
      if (!_isDomain(name)) {
        throw ArgumentError.value(name, 'domain', 'Expected a service domain');
      }
    }
    final compactSuffixes =
        suffixes.where((name) => !_hasParentSuffix(name, suffixes)).toList()
          ..sort();
    final compactDomains =
        exact
            .where(
              (name) =>
                  !suffixes.contains(name) && !_hasParentSuffix(name, suffixes),
            )
            .toList()
          ..sort();
    return SmartRouteDomainRules._(compactDomains, compactSuffixes);
  }

  final List<String> domains;
  final List<String> domainSuffixes;
  final List<String> xrayDomains;
  final Set<String> _exactSet;
  final Set<String> _suffixSet;

  static final _validLabel = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
  static final _ipv4Literal = RegExp(r'^\d+\.\d+\.\d+\.\d+$');

  static bool _isDomain(String name) =>
      name.length <= 253 &&
      name.contains('.') &&
      !_ipv4Literal.hasMatch(name) &&
      name.split('.').every((label) => _validLabel.hasMatch(label));

  bool matchesHost(String host) {
    final name = _normalize(host);
    if (!_isDomain(name)) return false;
    if (_exactSet.contains(name) || _suffixSet.contains(name)) return true;
    return _hasParentSuffix(name, _suffixSet);
  }

  static String _normalize(String name) {
    final normalized = name.trim().toLowerCase();
    return normalized.endsWith('.')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
  }

  static bool _hasParentSuffix(String name, Set<String> suffixes) {
    for (
      var dot = name.indexOf('.');
      dot >= 0;
      dot = name.indexOf('.', dot + 1)
    ) {
      if (suffixes.contains(name.substring(dot + 1))) {
        return true;
      }
    }
    return false;
  }
}
