part of 'home_screen.dart';

class _Strings {
  const _Strings._({
    required this.addProfileHint,
    required this.nothingToImport,
    required this.supportedProtocolsOnly,
    required this.switchingProfile,
    required this.importFirst,
    required this.autoConnectNoStableProfile,
    required this.configSaveFailed,
    required this.vpnStartFailed,
    required this.connectionProbeFailed,
    required this.disconnectingVpn,
    required this.vpnStopServiceFailed,
    required this.vpnStopped,
    required this.profileDeleted,
    required this.linkCopied,
    required this.close,
    required this.working,
    required this.report,
    required this.cannotOpenLink,
    required this.mailSubject,
    required this.mailFallback,
    required this.vpnStoppedUnexpectedly,
    required this.openLogsMessage,
    required this.languageChanged,
    required this.addProfile,
    required this.importHint,
    required this.importAction,
    required this.clipboard,
    required this.scanQr,
    required this.pasteFromClipboard,
    required this.language,
    required this.connected,
    required this.connectionProblem,
    required this.connecting,
    required this.disconnecting,
    required this.stopped,
    required this.profiles,
    required this.activeProfile,
    required this.refreshPing,
    required this.collapseProfiles,
    required this.serverPickerEmpty,
    required this.autoConnectMode,
    required this.openServers,
    required this.hideServers,
    required this.showQr,
    required this.copy,
    required this.delete,
    required this.emptyProfiles,
    required this.profileInsight,
    required this.profileInsightEmpty,
    required this.protocolLabel,
    required this.networkLabel,
    required this.dnsLabel,
    required this.dnsCountryValue,
    required this.dnsLeakGuardValue,
    required this.dnsWarpValue,
    required this.dnsLeakGuardEnabled,
    required this.dnsLeakGuardDisabled,
    required this.dnsLeakGuardApplying,
    required this.smartRouteLabel,
    required this.smartRouteEnabledValue,
    required this.smartRouteDisabledValue,
    required this.smartRouteEnabled,
    required this.smartRouteDisabled,
    required this.smartRouteApplying,
    required this.stabilityLabel,
    required this.stabilityValue,
    required this.backgroundModeLabel,
    required this.backgroundModeAllowed,
    required this.backgroundModeRestricted,
    required this.backgroundModeRequest,
    required this.batteryOptimizationSnack,
    required this.batteryOptimizationOpened,
    required this.countryLabel,
    required this.pingLabel,
    required this.subscriptionLabel,
    required this.subscriptionUnknown,
    required this.subscriptionExpired,
    required this.refreshSubscriptions,
    required this.refreshingSubscriptions,
    required this.noSubscriptionsToRefresh,
    required this.subscriptionReminderTitle,
    required this.mobileReady,
    required this.mobileNetworkAdvice,
    required this.androidVpnVisibleNote,
    required this.endpointLabel,
    required this.connect,
    required this.disconnect,
    required this.contact,
    required this.support,
    required this.donate,
    required this.developer,
    required this.updates,
    required this.updateDescription,
    required this.updateChannel,
    required this.checkUpdates,
    required this.updateChecking,
    required this.updateInstallerOpened,
    required this.updateInstallPermission,
    required this.openSettings,
    required this.faq,
    required this.faqItems,
    required this.logs,
    required this.noLogs,
    required this.notificationDescription,
  });

  final String addProfileHint;
  final String nothingToImport;
  final String supportedProtocolsOnly;
  final String switchingProfile;
  final String importFirst;
  final String autoConnectNoStableProfile;
  final String configSaveFailed;
  final String vpnStartFailed;
  final String connectionProbeFailed;
  final String disconnectingVpn;
  final String vpnStopServiceFailed;
  final String vpnStopped;
  final String profileDeleted;
  final String linkCopied;
  final String close;
  final String working;
  final String report;
  final String cannotOpenLink;
  final String mailSubject;
  final String mailFallback;
  final String vpnStoppedUnexpectedly;
  final String openLogsMessage;
  final String languageChanged;
  final String addProfile;
  final String importHint;
  final String importAction;
  final String clipboard;
  final String scanQr;
  final String pasteFromClipboard;
  final String language;
  final String connected;
  final String connectionProblem;
  final String connecting;
  final String disconnecting;
  final String stopped;
  final String profiles;
  final String activeProfile;
  final String refreshPing;
  final String collapseProfiles;
  final String serverPickerEmpty;
  final String autoConnectMode;
  final String openServers;
  final String hideServers;
  final String showQr;
  final String copy;
  final String delete;
  final String emptyProfiles;
  final String profileInsight;
  final String profileInsightEmpty;
  final String protocolLabel;
  final String networkLabel;
  final String dnsLabel;
  final String dnsCountryValue;
  final String dnsLeakGuardValue;
  final String dnsWarpValue;
  final String dnsLeakGuardEnabled;
  final String dnsLeakGuardDisabled;
  final String dnsLeakGuardApplying;
  final String smartRouteLabel;
  final String smartRouteEnabledValue;
  final String smartRouteDisabledValue;
  final String smartRouteEnabled;
  final String smartRouteDisabled;
  final String smartRouteApplying;
  final String stabilityLabel;
  final String stabilityValue;
  final String backgroundModeLabel;
  final String backgroundModeAllowed;
  final String backgroundModeRestricted;
  final String backgroundModeRequest;
  final String batteryOptimizationSnack;
  final String batteryOptimizationOpened;
  final String countryLabel;
  final String pingLabel;
  final String subscriptionLabel;
  final String subscriptionUnknown;
  final String subscriptionExpired;
  final String refreshSubscriptions;
  final String refreshingSubscriptions;
  final String noSubscriptionsToRefresh;
  final String subscriptionReminderTitle;
  final String mobileReady;
  final String mobileNetworkAdvice;
  final String androidVpnVisibleNote;
  final String endpointLabel;
  final String connect;
  final String disconnect;
  final String contact;
  final String support;
  final String donate;
  final String developer;
  final String updates;
  final String updateDescription;
  final String updateChannel;
  final String checkUpdates;
  final String updateChecking;
  final String updateInstallerOpened;
  final String updateInstallPermission;
  final String openSettings;
  final String faq;
  final List<_FaqItem> faqItems;
  final String logs;
  final String noLogs;
  final String notificationDescription;

  static _Strings forLanguage(_AppLanguage language) {
    return switch (language) {
      _AppLanguage.en => en,
      _ => ru,
    };
  }

  String loadedProfiles(int count) => switch (this) {
    _Strings.en => 'Profiles loaded: $count',
    _ => 'Загружено профилей: $count',
  };

  String imported(int count) => switch (this) {
    _Strings.en => 'Imported: $count',
    _ => 'Импортировано: $count',
  };

  String importedProfiles(int count) => switch (this) {
    _Strings.en => 'Profiles imported: $count',
    _ => 'Импортировано профилей: $count',
  };

  String subscriptionsUpdated(int count) => switch (this) {
    _Strings.en => 'Subscriptions updated: $count profiles',
    _ => 'Подписки обновлены: $count профилей',
  };

  String subscriptionRefreshFailed(String error) => switch (this) {
    _Strings.en => 'Subscription update failed: $error',
    _ => 'Обновление подписок не удалось: $error',
  };

  String subscriptionReminderBody(String profileName, String status) =>
      switch (this) {
        _Strings.en => '$profileName: $status. Time to renew the subscription.',
        _ => '$profileName: $status. Пора продлить подписку.',
      };

  String subscriptionReminderMany(
    int count,
    String profileName,
    String status,
  ) => switch (this) {
    _Strings.en =>
      '$count subscriptions need attention. First: $profileName, $status.',
    _ => '$count подписки требуют внимания. Первая: $profileName, $status.',
  };

  String profileTabLabel(_ProfileTab tab, int count) {
    final label = switch (tab) {
      _ProfileTab.all => switch (this) {
        _Strings.en => 'All',
        _ => 'Все',
      },
      _ProfileTab.vless => 'Reality',
      _ProfileTab.naive => 'HTTPS',
      _ProfileTab.hysteria => 'Turbo',
      _ProfileTab.experimental => switch (this) {
        _Strings.en => 'Experimental',
        _ => 'Эксперимент',
      },
    };
    return '$label $count';
  }

  String get stabilityNeedsAttention => switch (this) {
    _Strings.en => 'Needs attention',
    _ => 'Требует внимания',
  };

  String get profileStabilityLabel => switch (this) {
    _Strings.en => 'Profile rating',
    _ => 'Рейтинг профиля',
  };

  String get profileStabilityGood => switch (this) {
    _Strings.en => 'Stable',
    _ => 'Стабильный',
  };

  String get profileStabilityLearning => switch (this) {
    _Strings.en => 'Learning',
    _ => 'Наблюдение',
  };

  String get profileStabilityWeak => switch (this) {
    _Strings.en => 'Weak',
    _ => 'Слабый',
  };

  String get profileStabilityCoolingDown => switch (this) {
    _Strings.en => 'Cooling down',
    _ => 'Остывает',
  };

  String get keeperLabel => switch (this) {
    _Strings.en => 'Keeper',
    _ => 'Keeper',
  };

  String get keeperActive => switch (this) {
    _Strings.en => 'Active',
    _ => 'Активен',
  };

  String get keeperIdle => switch (this) {
    _Strings.en => 'Waiting',
    _ => 'Ожидает',
  };

  String get keeperChecking => switch (this) {
    _Strings.en => 'Checking',
    _ => 'Проверка',
  };

  String get keeperReconnecting => switch (this) {
    _Strings.en => 'Reconnecting',
    _ => 'Переподключение',
  };

  String get keeperDegraded => switch (this) {
    _Strings.en => 'Degraded',
    _ => 'Нестабильно',
  };

  String get idleKeeperLabel => switch (this) {
    _Strings.en => 'Idle keeper',
    _ => 'Ночной keeper',
  };

  String get idleKeeperReady => switch (this) {
    _Strings.en => 'Ready',
    _ => 'Готов',
  };

  String get idleKeeperActive => switch (this) {
    _Strings.en => 'Checked',
    _ => 'Проверено',
  };

  String get idleConnection => switch (this) {
    _Strings.en => 'Idle',
    _ => 'Ожидание',
  };

  String get reconnectingConnection => switch (this) {
    _Strings.en => 'Reconnecting',
    _ => 'Переподключение',
  };

  String get lastCheckLabel => switch (this) {
    _Strings.en => 'Last check',
    _ => 'Проверка',
  };

  String get lastCheckNever => switch (this) {
    _Strings.en => 'Not yet',
    _ => 'Ещё не было',
  };

  String lastCheckAgo(Duration duration) {
    final safe = duration.isNegative ? Duration.zero : duration;
    if (safe.inSeconds < 60) {
      final seconds = safe.inSeconds.clamp(1, 59);
      return switch (this) {
        _Strings.en => '${seconds}s ago',
        _ => '$seconds сек назад',
      };
    }
    if (safe.inMinutes < 60) {
      return switch (this) {
        _Strings.en => '${safe.inMinutes}m ago',
        _ => '${safe.inMinutes} мин назад',
      };
    }
    return switch (this) {
      _Strings.en => '${safe.inHours}h ago',
      _ => '${safe.inHours} ч назад',
    };
  }

  String get autoRecoveryLabel => switch (this) {
    _Strings.en => 'Recovery',
    _ => 'Автовосстановление',
  };

  String get autoRecoveryOn => switch (this) {
    _Strings.en => 'On',
    _ => 'Включено',
  };

  String get autoRecoveryOff => switch (this) {
    _Strings.en => 'Off',
    _ => 'Выключено',
  };

  String get healthFailuresLabel => switch (this) {
    _Strings.en => 'Failures',
    _ => 'Сбои',
  };

  String get healthFailuresNone => switch (this) {
    _Strings.en => 'None',
    _ => 'Нет',
  };

  String healthFailuresCount(int count) => switch (this) {
    _Strings.en => '$count in a row',
    _ => '$count подряд',
  };

  String noProfilesInTab(_ProfileTab tab) => switch (this) {
    _Strings.en => 'No profiles in this tab yet.',
    _ => 'В этой вкладке пока нет профилей.',
  };

  String showMoreProfiles(int count) => switch (this) {
    _Strings.en => 'Show $count more',
    _ => 'Показать ещё: $count',
  };

  String supportTabLabel(_SupportTab tab) => switch (tab) {
    _SupportTab.help => switch (this) {
      _Strings.en => 'Help',
      _ => 'Помощь',
    },
    _SupportTab.community => switch (this) {
      _Strings.en => 'Project',
      _ => 'Проект',
    },
  };

  String selectedProfile(String name) => switch (this) {
    _Strings.en => 'Selected profile: $name',
    _ => 'Выбран профиль: $name',
  };

  String autoSelectedProfile(String name) => switch (this) {
    _Strings.en => 'Auto selected: $name',
    _ => 'Автовыбор: $name',
  };

  String serverPickerTitle(int count) => switch (this) {
    _Strings.en => 'Servers: $count',
    _ => 'Серверы: $count',
  };

  String visibleServers(int count) => switch (this) {
    _Strings.en => 'In tab: $count',
    _ => 'В разделе: $count',
  };

  String connectingTo(String name) => switch (this) {
    _Strings.en => 'Connecting to $name...',
    _ => 'Подключаю $name...',
  };

  String connectingStatus(String name) => switch (this) {
    _Strings.en => 'Connecting: $name',
    _ => 'Подключаюсь: $name',
  };

  String connectionProfile(String name) => switch (this) {
    _Strings.en => 'Connection: $name',
    _ => 'Подключение: $name',
  };

  String unsupportedProtocol(VpnProfileKind kind) => switch (this) {
    _Strings.en =>
      '${kind.label} is not enabled in this Android build. Use VLESS Reality, NaiveProxy, or Hysteria/Hysteria2.',
    _ =>
      '${kind.label} отключён в этой Android-сборке. Используй VLESS Reality, NaiveProxy или Hysteria/Hysteria2.',
  };

  String networkRecoveryPaused(String name) => switch (this) {
    _Strings.en =>
      'Mobile network is unstable. Auto reconnect is paused for $name.',
    _ => 'Мобильная сеть нестабильна. Автовосстановление для $name на паузе.',
  };

  String vpnNotConnected(String status) => switch (this) {
    _Strings.en => 'VPN did not reach Connected. Last status: $status.',
    _ => 'VPN не вышел в статус "Подключено". Последний статус: $status.',
  };

  String vpnStopTimeout(String status) => switch (this) {
    _Strings.en => 'VPN did not fully stop in time. Last status: $status.',
    _ => 'VPN не успел полностью остановиться. Последний статус: $status.',
  };

  String updateIdle(String version) => switch (this) {
    _Strings.en => 'Installed version: $version',
    _ => 'Установлена версия: $version',
  };

  String updateAvailable(String version) => switch (this) {
    _Strings.en => 'New version available: $version',
    _ => 'Доступна новая версия: $version',
  };

  String updateAvailableSnack(String version) => switch (this) {
    _Strings.en => 'Yurich Connect $version is available.',
    _ => 'Вышла новая версия Yurich Connect $version.',
  };

  String get updateAvailableTitle => switch (this) {
    _Strings.en => 'Yurich Connect update',
    _ => 'Обновление Yurich Connect',
  };

  String updateAvailableBody(String version) => switch (this) {
    _Strings.en => 'Version $version is ready. Open Updates to install it.',
    _ => 'Версия $version готова. Открой обновления и установи её.',
  };

  String get updateNow => switch (this) {
    _Strings.en => 'Update',
    _ => 'Обновить',
  };

  String get downloadApk => switch (this) {
    _Strings.en => 'APK',
    _ => 'APK',
  };

  String updateNoUpdates(String version) => switch (this) {
    _Strings.en => 'Version $version is current.',
    _ => 'Версия $version актуальна.',
  };

  String updateDownloading(String version) => switch (this) {
    _Strings.en => 'Downloading version $version...',
    _ => 'Скачиваю версию $version...',
  };

  String updateDownloadingProgress(String version, int percent) =>
      switch (this) {
        _Strings.en => 'Downloading version $version: $percent%',
        _ => 'Скачиваю версию $version: $percent%',
      };

  String updateInstalling(String version) => switch (this) {
    _Strings.en => 'Version $version downloaded. Opening installer...',
    _ => 'Версия $version скачана. Открываю установщик...',
  };

  String updateFailed(String error) => switch (this) {
    _Strings.en => 'Update failed: $error',
    _ => 'Обновление не удалось: $error',
  };

  String subscriptionStatus(DateTime? expiresAt) {
    if (expiresAt == null) {
      return subscriptionUnknown;
    }

    final remaining = expiresAt.toUtc().difference(DateTime.now().toUtc());
    if (remaining.isNegative) {
      return subscriptionExpired;
    }

    if (remaining.inHours < 24) {
      final hours = remaining.inHours.clamp(1, 23);
      return switch (this) {
        _Strings.en => '$hours h left',
        _ => 'Осталось $hours ч',
      };
    }

    final days = remaining.inDays + (remaining.inHours % 24 == 0 ? 0 : 1);
    return switch (this) {
      _Strings.en => '$days d left',
      _ => 'Осталось $days дн.',
    };
  }

  static const ru = _Strings._(
    addProfileHint: 'Добавь подписку Remnawave, QR или отдельный ключ',
    nothingToImport: 'Нечего импортировать.',
    supportedProtocolsOnly:
        'В этой сборке поддерживаются VLESS Reality, NaiveProxy и Hysteria/Hysteria2. pingtunnel:// пока только для просмотра в разделе Эксперимент.',
    switchingProfile: 'Переключаю профиль...',
    importFirst: 'Сначала импортируй профиль.',
    autoConnectNoStableProfile:
        'Для авто-подключения нужен рабочий Reality или HTTPS профиль. Turbo/Hysteria не запускается автоматически.',
    configSaveFailed: 'sing-box не сохранил config.',
    vpnStartFailed: 'VPN не стартовал. Открой логи ниже.',
    connectionProbeFailed:
        'VPN запустился, но проверка интернета через туннель не прошла.',
    disconnectingVpn: 'Отключаю VPN...',
    vpnStopServiceFailed: 'VPN-сервис не смог полностью остановиться.',
    vpnStopped: 'VPN остановлен',
    profileDeleted: 'Профиль удалён',
    linkCopied: 'Ссылка скопирована',
    close: 'Закрыть',
    working: 'Работаю...',
    report: 'Отчёт',
    cannotOpenLink: 'Не смог открыть ссылку.',
    mailSubject: 'Yurich Connect: диагностика VPN',
    mailFallback: 'Почта не открылась. Отчёт скопирован в буфер.',
    vpnStoppedUnexpectedly: 'VPN остановлен неожиданно',
    openLogsMessage: 'VPN остановлен. Открой логи sing-box.',
    languageChanged: 'Язык переключён',
    addProfile: 'Добавить профиль',
    importHint:
        'https://sub... или vless:// Reality, naive+https://..., hy2://..., pingtunnel://',
    importAction: 'Импорт',
    clipboard: 'Буфер',
    scanQr: 'Сканировать QR',
    pasteFromClipboard: 'Вставить из буфера',
    language: 'Язык',
    connected: 'Подключено',
    connectionProblem: 'Нет стабильного соединения',
    connecting: 'Подключаюсь',
    disconnecting: 'Отключаюсь',
    stopped: 'Остановлено',
    profiles: 'Профили',
    activeProfile: 'Активен',
    refreshPing: 'Обновить пинг',
    collapseProfiles: 'Свернуть список',
    serverPickerEmpty: 'Сервер не выбран',
    autoConnectMode: 'Автовыбор Reality/HTTPS, Turbo только вручную',
    openServers: 'Открыть',
    hideServers: 'Скрыть',
    showQr: 'Показать QR',
    copy: 'Скопировать',
    delete: 'Удалить',
    emptyProfiles:
        'Пока нет профилей. Нажми +, вставь подписку или сканируй QR.',
    profileInsight: 'Профиль и сеть',
    profileInsightEmpty:
        'Выбери профиль, чтобы увидеть параметры подключения и рекомендации.',
    protocolLabel: 'Протокол',
    networkLabel: 'Сеть',
    dnsLabel: 'DNS',
    dnsCountryValue: 'Auto resolver',
    dnsLeakGuardValue: 'Auto DNS',
    dnsWarpValue: 'WARP',
    dnsLeakGuardEnabled: 'Auto DNS включён',
    dnsLeakGuardDisabled: 'Auto DNS выключен',
    dnsLeakGuardApplying: 'Применяю Auto DNS...',
    smartRouteLabel: 'Smart Route',
    smartRouteEnabledValue: 'RU direct / Global VPN',
    smartRouteDisabledValue: 'Всё через VPN',
    smartRouteEnabled: 'Smart Route включён',
    smartRouteDisabled: 'Smart Route выключен',
    smartRouteApplying: 'Применяю Smart Route...',
    stabilityLabel: 'Стабильность',
    stabilityValue: 'Фоновый keeper',
    backgroundModeLabel: 'Фон',
    backgroundModeAllowed: 'Без ограничений',
    backgroundModeRestricted: 'Ограничен батареей',
    backgroundModeRequest: 'Разрешить',
    batteryOptimizationSnack:
        'Для круглосуточной работы разреши Yurich Connect работу без ограничений батареи.',
    batteryOptimizationOpened:
        'Открыл настройки батареи. Разреши работу без ограничений и вернись в приложение.',
    countryLabel: 'Страна',
    pingLabel: 'Пинг',
    subscriptionLabel: 'Подписка',
    subscriptionUnknown: 'Срок не указан',
    subscriptionExpired: 'Истекла',
    refreshSubscriptions: 'Обновить подписки',
    refreshingSubscriptions: 'Обновляю подписки...',
    noSubscriptionsToRefresh:
        'Не нашёл исходную ссылку подписки. Вставь https://.../s/... или https://.../links.txt один раз.',
    subscriptionReminderTitle: 'Пора продлить подписку',
    mobileReady: 'Wi‑Fi / LTE',
    mobileNetworkAdvice:
        'Wi‑Fi/LTE: строгий TUN, FakeIP и фоновый keeper; туннель перепроверяется без открытия приложения.',
    androidVpnVisibleNote:
        'Android может показать приложениям факт VPN. Yurich Connect защищает IP/DNS, но системный VpnService не скрывается без root/прошивки.',
    endpointLabel: 'Сервер',
    connect: 'Подключить',
    disconnect: 'Отключить',
    contact: 'Связь',
    support: 'Поддержка',
    donate: 'Донат',
    developer: 'Разработчику',
    updates: 'Обновления',
    updateDescription:
        'Приложение само проверит свежий APK, выберет файл под телефон и откроет установщик Android. Переходить на страницу релиза не нужно.',
    updateChannel: 'Канал обновлений: GitHub Releases',
    checkUpdates: 'Проверить и установить',
    updateChecking: 'Проверяю обновления...',
    updateInstallerOpened: 'Установщик Android открыт',
    updateInstallPermission:
        'Разреши установку приложений из Yurich Connect и нажми кнопку ещё раз.',
    openSettings: 'Настройки',
    faq: 'FAQ',
    faqItems: [
      _FaqItem(
        question: 'Как добавить подписку или ключ?',
        answer:
            'Нажми + в разделе профилей. Можно вставить ссылку вручную, из буфера или отсканировать QR.',
      ),
      _FaqItem(
        question: 'Какие протоколы поддерживаются?',
        answer:
            'В Android-клиенте оставлены стабильные направления: VLESS Reality, NaiveProxy и Hysteria/Hysteria2. XHTTP, mKCP, TLS-only VLESS и raw sing-box JSON не показываются в профилях этой сборки.',
      ),
      _FaqItem(
        question: 'Что делать, если после смены профиля пропал интернет?',
        answer:
            'Нажми Отключить, подожди статус Остановлено и подключи профиль снова. Если проблема повторяется, отправь отчёт разработчику.',
      ),
      _FaqItem(
        question: 'Почему нужна шторка уведомления?',
        answer:
            'Android требует постоянное уведомление для VPN. Разреши уведомления, чтобы видеть статус и скорость в шторке.',
      ),
      _FaqItem(
        question: 'Почему теперь лучше работает мобильная сеть?',
        answer:
            'Приложение использует единый сетевой режим для Wi‑Fi и LTE: аккуратное переподключение, строгий TUN и устойчивую маршрутизацию через туннель.',
      ),
      _FaqItem(
        question: 'Безопасно ли отправлять отчёт?',
        answer:
            'Отчёт открывается в твоей почте перед отправкой. Пароли, UUID и ключи скрываются автоматически.',
      ),
    ],
    logs: 'Логи sing-box',
    noLogs: 'Логов пока нет.',
    notificationDescription: 'VPN подключение активно',
  );

  static const en = _Strings._(
    addProfileHint: 'Add a Remnawave subscription, QR code, or single key',
    nothingToImport: 'Nothing to import.',
    supportedProtocolsOnly:
        'This build supports VLESS Reality, NaiveProxy, and Hysteria/Hysteria2. pingtunnel:// is shown as Experimental only.',
    switchingProfile: 'Switching profile...',
    importFirst: 'Import a profile first.',
    autoConnectNoStableProfile:
        'Auto connect needs a working Reality or HTTPS profile. Turbo/Hysteria is not started automatically.',
    configSaveFailed: 'sing-box did not save the config.',
    vpnStartFailed: 'VPN did not start. Check the logs below.',
    connectionProbeFailed:
        'VPN started, but the tunnel internet probe did not pass.',
    disconnectingVpn: 'Disconnecting VPN...',
    vpnStopServiceFailed: 'VPN service could not fully stop.',
    vpnStopped: 'VPN stopped',
    profileDeleted: 'Profile deleted',
    linkCopied: 'Link copied',
    close: 'Close',
    working: 'Working...',
    report: 'Report',
    cannotOpenLink: 'Could not open the link.',
    mailSubject: 'Yurich Connect: VPN diagnostics',
    mailFallback: 'Mail did not open. Report copied to clipboard.',
    vpnStoppedUnexpectedly: 'VPN stopped unexpectedly',
    openLogsMessage: 'VPN stopped. Open sing-box logs.',
    languageChanged: 'Language changed',
    addProfile: 'Add profile',
    importHint:
        'https://sub... or VLESS Reality, naive+https://..., hy2://..., pingtunnel://',
    importAction: 'Import',
    clipboard: 'Clipboard',
    scanQr: 'Scan QR',
    pasteFromClipboard: 'Paste from clipboard',
    language: 'Language',
    connected: 'Connected',
    connectionProblem: 'Connection problem',
    connecting: 'Connecting',
    disconnecting: 'Disconnecting',
    stopped: 'Stopped',
    profiles: 'Profiles',
    activeProfile: 'Active',
    refreshPing: 'Refresh ping',
    collapseProfiles: 'Collapse list',
    serverPickerEmpty: 'No server selected',
    autoConnectMode: 'Auto selects Reality/HTTPS; Turbo is manual only',
    openServers: 'Open',
    hideServers: 'Hide',
    showQr: 'Show QR',
    copy: 'Copy',
    delete: 'Delete',
    emptyProfiles: 'No profiles yet. Tap +, paste a subscription, or scan QR.',
    profileInsight: 'Profile and network',
    profileInsightEmpty:
        'Select a profile to see connection parameters and recommendations.',
    protocolLabel: 'Protocol',
    networkLabel: 'Network',
    dnsLabel: 'DNS',
    dnsCountryValue: 'Auto resolver',
    dnsLeakGuardValue: 'Auto DNS',
    dnsWarpValue: 'WARP',
    dnsLeakGuardEnabled: 'Auto DNS enabled',
    dnsLeakGuardDisabled: 'Auto DNS disabled',
    dnsLeakGuardApplying: 'Applying Auto DNS...',
    smartRouteLabel: 'Smart Route',
    smartRouteEnabledValue: 'RU direct / Global VPN',
    smartRouteDisabledValue: 'All traffic through VPN',
    smartRouteEnabled: 'Smart Route enabled',
    smartRouteDisabled: 'Smart Route disabled',
    smartRouteApplying: 'Applying Smart Route...',
    stabilityLabel: 'Stability',
    stabilityValue: 'Background keeper',
    backgroundModeLabel: 'Background',
    backgroundModeAllowed: 'Unrestricted',
    backgroundModeRestricted: 'Battery restricted',
    backgroundModeRequest: 'Allow',
    batteryOptimizationSnack:
        'For 24/7 VPN, allow Yurich Connect to run without battery restrictions.',
    batteryOptimizationOpened:
        'Battery settings opened. Allow unrestricted background work, then return to the app.',
    countryLabel: 'Country',
    pingLabel: 'Ping',
    subscriptionLabel: 'Subscription',
    subscriptionUnknown: 'Not provided',
    subscriptionExpired: 'Expired',
    refreshSubscriptions: 'Refresh subscriptions',
    refreshingSubscriptions: 'Refreshing subscriptions...',
    noSubscriptionsToRefresh:
        'No saved subscription source. Paste the https://.../s/... or https://.../links.txt URL once.',
    subscriptionReminderTitle: 'Subscription renewal',
    mobileReady: 'Wi‑Fi / LTE',
    mobileNetworkAdvice:
        'Wi-Fi/LTE: strict TUN, FakeIP, and a background keeper that checks the tunnel without opening the app.',
    androidVpnVisibleNote:
        'Android can expose VPN status to apps. Yurich Connect protects IP/DNS, but system VpnService cannot be hidden without root/custom firmware.',
    endpointLabel: 'Server',
    connect: 'Connect',
    disconnect: 'Disconnect',
    contact: 'Contact',
    support: 'Support',
    donate: 'Donate',
    developer: 'Developer',
    updates: 'Updates',
    updateDescription:
        'The app checks for a fresh APK, picks the right file for this phone, and opens the Android installer. No release page is opened.',
    updateChannel: 'Update channel: GitHub Releases',
    checkUpdates: 'Check and install',
    updateChecking: 'Checking updates...',
    updateInstallerOpened: 'Android installer opened',
    updateInstallPermission:
        'Allow app installs from Yurich Connect, then press the button again.',
    openSettings: 'Settings',
    faq: 'FAQ',
    faqItems: [
      _FaqItem(
        question: 'How do I add a subscription or key?',
        answer:
            'Use the add button in Profiles. You can paste manually, import from clipboard, or scan a QR code.',
      ),
      _FaqItem(
        question: 'Which protocols are supported?',
        answer:
            'The Android client focuses on stable profiles: VLESS Reality, NaiveProxy, and Hysteria/Hysteria2. XHTTP, mKCP, TLS-only VLESS, and raw sing-box JSON are hidden in this build. PingTunnel (Experimental) is shown for tracking and is not started in this build.',
      ),
      _FaqItem(
        question: 'What if internet stops after switching profiles?',
        answer:
            'Tap Disconnect, wait for Stopped, then connect again. If it repeats, send a developer report.',
      ),
      _FaqItem(
        question: 'Why does Android need a notification?',
        answer:
            'Android requires a persistent notification for VPN. Allow notifications to see status and speed in the shade.',
      ),
      _FaqItem(
        question: 'Why should mobile networks work better now?',
        answer:
            'The app uses one network baseline for Wi-Fi and LTE: smoother reconnects, strict TUN, and stable tunnel routing.',
      ),
      _FaqItem(
        question: 'Is sending a report safe?',
        answer:
            'The report opens in your email before sending. Passwords, UUIDs, and keys are hidden automatically.',
      ),
    ],
    logs: 'sing-box logs',
    noLogs: 'No logs yet.',
    notificationDescription: 'VPN connection is active',
  );
}
