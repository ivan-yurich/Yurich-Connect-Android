part of 'home_screen.dart';

enum _MobilePage { home, servers, settings }

enum _MobileServerAction { details, check, delete }

enum _MobileListAction { refresh, qr, copy, help }

enum _MobileImportAction { input, clipboard, qr }

enum _MobilePillTone { blue, neutral, warning }

enum _MobilePowerTone { off, active, pending, problem }

typedef _MobileLatency = ({String label, _MobilePillTone tone});

extension _MobileHomeView on _HomeScreenState {
  Widget _buildMobile(
    VpnProfile? selected,
    VpnProfile? explicitSelected,
    VpnProfile? connectCandidate,
  ) {
    // The selection changes before a queued switch applies its config.
    // Do not badge the new selection as active in that interval.
    final transition = _busy && _connectionQueueActive;
    final active =
        _status == AurumVpnStatus.started &&
            !transition &&
            explicitSelected?.id != _unconfirmedSwitchProfileId
        ? explicitSelected
        : null;
    return _MobileShell(
      page: _mobilePage,
      strings: s,
      version: _appVersion,
      serverCount: _profiles.length,
      serverActions: _mobilePage == _MobilePage.servers
          ? _mobileServerActions(selected)
          : const [],
      onNavigate: _navigateMobile,
      onImport: _preparingAutoConnect
          ? null
          : () => unawaited(_showImportSheet()),
      child: switch (_mobilePage) {
        _MobilePage.home => _mobileDashboard(
          connectCandidate,
          active,
          transition,
        ),
        _MobilePage.servers => _mobileServers(selected, active),
        _MobilePage.settings => _mobileSettings(selected),
      },
    );
  }

  String _mobileName(VpnProfile profile) =>
      SensitiveDataRedactor.redact(_profileDisplayName(profile));

  String _mobileDetails(VpnProfile profile) => [
    ProtocolDisplayMapper.mapProfile(profile),
    ?_profileCountryName(profile),
  ].join(' · ');

  bool get _mobileCanProbe =>
      _status == AurumVpnStatus.started &&
      !_busy &&
      !_connectionQueueActive &&
      _unconfirmedSwitchProfileId == null &&
      _explicitSelectedProfile?.kind.isClientSupported == true;

  bool get _mobileCanRefresh =>
      !_busy &&
      !_subscriptionRefreshBusy &&
      !_preparingAutoConnect &&
      _profiles.isNotEmpty;

  _MobileLatency _mobileLatency(VpnProfile profile) {
    final offline = ProtocolTestMetadata.isOfflineMarked(profile);
    final russian = _language == _AppLanguage.ru;
    if (offline) {
      return (
        label: const ServerProbeResult(
          ServerProbeState.offlineMarked,
        ).label(russian: russian),
        tone: _MobilePillTone.warning,
      );
    }
    if (profile.id == _unconfirmedSwitchProfileId) {
      return (
        label: const ServerProbeResult(
          ServerProbeState.cancelled,
        ).label(russian: russian),
        tone: _MobilePillTone.neutral,
      );
    }
    if (_status == AurumVpnStatus.started && profile.id == _selectedProfileId) {
      return _mobileActiveLatency(profile) ??
          (label: s.directLatencyNotMeasured, tone: _MobilePillTone.neutral);
    }
    final direct = _directReadings[profile.id];
    if (_directLatencyAllowed == true &&
        !_smartRoutePausedByKillSwitch &&
        direct != null &&
        direct.network == _probePhysicalNetwork &&
        DateTime.now().difference(direct.at) < const Duration(minutes: 3)) {
      return (
        label: s.directLatencyValue(direct.reading, cached: _connected),
        tone: _MobilePillTone.blue,
      );
    }
    if (_status == AurumVpnStatus.started &&
        profile.id != _selectedProfileId &&
        ServerProbeTarget.usesUdp(profile)) {
      return (
        label: const ServerProbeResult(
          ServerProbeState.needsConnection,
        ).label(russian: russian),
        tone: _MobilePillTone.neutral,
      );
    }
    if (_canMeasureDirectLatency &&
        _directLatencyAllowed != false &&
        DirectLatencyProbe.eligible(profile)) {
      return (label: s.directLatencyNotMeasured, tone: _MobilePillTone.neutral);
    }
    final label = _profilePingLabel(profile);
    final state =
        _status == AurumVpnStatus.started &&
            _profilePingBusy[profile.id] != true
        ? _profileProbeResults[profile.id]?.state
        : null;
    return (
      label: label,
      tone: switch (state) {
        ServerProbeState.tlsReachable ||
        ServerProbeState.tunnelHealthy => _MobilePillTone.blue,
        ServerProbeState.noResponse ||
        ServerProbeState.certificateUnverified => _MobilePillTone.warning,
        _ => _MobilePillTone.neutral,
      },
    );
  }

  _MobileLatency? _mobileActiveLatency(VpnProfile profile) {
    final result = _profileProbeResults[profile.id];
    if (result?.state != ServerProbeState.tunnelHealthy ||
        result?.milliseconds == null) {
      return null;
    }
    return (
      label: result!.label(russian: _language == _AppLanguage.ru),
      tone: _MobilePillTone.blue,
    );
  }

  Widget _mobileDashboard(
    VpnProfile? candidate,
    VpnProfile? active,
    bool transition,
  ) {
    final connection = _connectionUiState;
    var status = connection.status;
    if ((status == ConnectionStatus.degraded ||
            status == ConnectionStatus.failed) &&
        !_vpnUiCommandFailed &&
        _lastRecoverySource == null &&
        _tunnelHealthFailures == 0 &&
        !_isTunnelStale(DateTime.now())) {
      // An unrelated error (for example, refreshing subscriptions) can leave
      // a notice. It is not evidence that the currently running VPN failed.
      status = _status == AurumVpnStatus.started
          ? ConnectionStatus.connected
          : ConnectionStatus.disconnected;
    }
    final activeProbe = active == null ? null : _profileProbeResults[active.id];
    final handoverReady =
        status == ConnectionStatus.networkChanging &&
        _tunnelHealthFailures == 0 &&
        activeProbe?.state == ServerProbeState.tunnelHealthy;
    if (_stopProtectionCheck ||
        _userStopQueued ||
        _preparingAutoConnect ||
        _status == AurumVpnStatus.stopping ||
        (transition && _manualDisconnectRequested)) {
      status = ConnectionStatus.connecting;
    } else if (transition) {
      status = _status == AurumVpnStatus.started
          ? ConnectionStatus.reconnecting
          : ConnectionStatus.connecting;
    } else if (_vpnUiCommandFailed &&
        status != ConnectionStatus.connecting &&
        status != ConnectionStatus.reconnecting &&
        (status != ConnectionStatus.networkChanging || handoverReady)) {
      status = ConnectionStatus.failed;
    } else if (handoverReady) {
      // Probe results are invalidated on network change. This success belongs
      // to the current VPN generation, so the UI need not wait out the
      // watchdog's full settling window.
      status = ConnectionStatus.connected;
    }
    final tone = switch (status) {
      ConnectionStatus.connected ||
      ConnectionStatus.idle => _MobilePowerTone.active,
      ConnectionStatus.degraded ||
      ConnectionStatus.failed => _MobilePowerTone.problem,
      ConnectionStatus.connecting ||
      ConnectionStatus.reconnecting ||
      ConnectionStatus.networkChanging => _MobilePowerTone.pending,
      ConnectionStatus.disconnected => _MobilePowerTone.off,
    };
    final statusLabel = switch (status) {
      ConnectionStatus.connected => s.connected,
      ConnectionStatus.idle => s.idleConnection,
      ConnectionStatus.networkChanging ||
      ConnectionStatus.reconnecting => s.reconnectingConnection,
      ConnectionStatus.degraded ||
      ConnectionStatus.failed => s.connectionProblem,
      ConnectionStatus.connecting =>
        _stopProtectionCheck || _userStopQueued
            ? s.disconnecting
            : _preparingAutoConnect
            ? s.choosingAutoServer
            : _status == AurumVpnStatus.stopping ||
                  (transition && _manualDisconnectRequested)
            ? s.disconnecting
            : s.connecting,
      ConnectionStatus.disconnected =>
        candidate == null ? s.serverPickerEmpty : s.tapToConnect,
    };
    final routineMessages = {
      '',
      s.loadedProfiles(_profiles.length),
      s.vpnStopped,
      if (_preparingAutoConnect) s.choosingAutoServer,
      if (candidate != null) s.selectedProfile(candidate.name),
      if (active != null) s.connectionProfile(active.name),
    };
    void openServers() => _navigateMobile(_MobilePage.servers);

    return _MobileHome(
      emptyAction: _profiles.isEmpty && !_connected
          ? FilledButton.icon(
              key: const ValueKey('mobile-empty-add-subscription'),
              onPressed:
                  _busy || _connectionQueueActive || _preparingAutoConnect
                  ? null
                  : () => unawaited(_showImportSheet()),
              icon: const Icon(Icons.add_rounded),
              label: Text(s.addSubscription),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            )
          : null,
      picker: _MobileServerPicker(
        name: active != null || candidate == null
            ? s.serversTitle
            : _automaticProfileSelection
            ? s.automaticServer
            : _mobileName(candidate),
        flag: candidate == null || active != null || _automaticProfileSelection
            ? null
            : _profileCountryFlag(candidate),
        strings: s,
        refreshing: _subscriptionRefreshBusy,
        onOpen: openServers,
        onRefresh: _mobileCanRefresh
            ? () => unawaited(_refreshSubscriptions())
            : null,
      ),
      hero: (diameter) => _MobileConnectionHero(
        diameter: diameter,
        connection: connection,
        strings: s,
        statusLabel: statusLabel,
        action: _canCancelVpnStart
            ? s.cancelConnectionAction
            : _connected
            ? s.disconnectAction
            : s.connectAction,
        tone: tone,
        showTraffic: _connected || _status == AurumVpnStatus.stopping,
        notice:
            _vpnUiCommandFailed &&
                status == ConnectionStatus.failed &&
                _message != s.autoExhausted
            ? s.vpnFailureMessage(_lastVpnFailureCategory)
            : routineMessages.contains(_message)
            ? null
            : SensitiveDataRedactor.redact(_message),
        latency: active == null ? null : _mobileActiveLatency(active),
        onToggle:
            !_stopProtectionCheck &&
                !_userStopQueued &&
                (_canCancelVpnStart ||
                    (!_busy &&
                        !_connectionQueueActive &&
                        (_connected ||
                            (_smartRoutePreferenceLoaded &&
                                _profiles.isNotEmpty))))
            ? () => unawaited(_toggleVpn())
            : null,
      ),
      activeServer: active == null
          ? null
          : _MobileActiveServer(
              label: s.activeServer,
              location: _profileCountryName(active) ?? s.unknownLocation,
              flag: _profileCountryFlag(active),
              onTap: openServers,
            ),
    );
  }

  bool get _mobileCanDirectProbe =>
      _canMeasureDirectLatency &&
      !_preparingAutoConnect &&
      _directLatencyAllowed != false &&
      _directLatencyProbe == null;

  Future<void> _checkMobileLatency(List<VpnProfile> profiles) async {
    if (_mobileCanProbe) {
      if (profiles.length == 1) {
        await _pingProfile(profiles.single, force: true);
      } else {
        await _pingProfiles(profiles, force: true);
      }
      return;
    }
    if (!_mobileCanDirectProbe || !await _confirmDirectLatency()) return;
    final results = await _measureDirectLatency(profiles, automatic: false);
    if (mounted && results.isEmpty && !_connected) {
      _showSnack(s.directLatencyUnavailable);
    }
  }

  List<Widget> _mobileServerActions(VpnProfile? selected) => [
    IconButton(
      key: const ValueKey('mobile-check-servers'),
      tooltip: _connected ? s.refreshPing : s.directLatencySetting,
      onPressed:
          _profiles.isNotEmpty &&
              ((_mobileCanProbe && !_pingAllInFlight) || _mobileCanDirectProbe)
          ? () => unawaited(_checkMobileLatency(_profiles))
          : null,
      icon: _directLatencyProbe != null || _pingAllInFlight
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.speed_outlined),
    ),
    PopupMenuButton<_MobileListAction>(
      key: const ValueKey('mobile-server-list-menu'),
      tooltip: s.listActions,
      onSelected: (action) {
        switch (action) {
          case _MobileListAction.refresh:
            unawaited(_refreshSubscriptions());
          case _MobileListAction.qr:
            unawaited(_showQr());
          case _MobileListAction.copy:
            unawaited(_copySelected());
          case _MobileListAction.help:
            unawaited(_showLatencyHelp());
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: _MobileListAction.refresh,
          enabled: _mobileCanRefresh,
          child: Text(s.refreshSubscriptions),
        ),
        PopupMenuItem(
          value: _MobileListAction.qr,
          enabled: selected != null,
          child: Text(s.showQr),
        ),
        PopupMenuItem(
          value: _MobileListAction.copy,
          enabled: selected != null,
          child: Text(s.copy),
        ),
        PopupMenuItem(value: _MobileListAction.help, child: Text(s.probeHelp)),
      ],
    ),
  ];

  Future<void> _showLatencyHelp() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(s.probeHelp),
      content: Text('${s.latencyMethods}\n\n${s.reachabilityInfo}'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.close),
        ),
      ],
    ),
  );

  Future<void> _showMobileServerDetails(
    BuildContext context,
    VpnProfile profile,
  ) {
    final subscription = _subscriptionTileStatus(profile);
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_mobileName(profile)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_mobileDetails(profile)),
            if (subscription != null)
              Text('${s.subscriptionLabel}: $subscription'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(s.close),
          ),
        ],
      ),
    );
  }

  Widget _mobileServers(VpnProfile? selected, VpnProfile? active) {
    final selectedId = _automaticProfileSelection && active == null
        ? null
        : selected?.id;
    final profiles = [
      ..._profiles.where((profile) => profile.id == selectedId),
      ..._profiles.where((profile) => profile.id != selectedId),
    ];
    final canProbe = _mobileCanProbe;
    final canDirect = _mobileCanDirectProbe;
    return CustomScrollView(
      key: const PageStorageKey('mobile-servers-scroll'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          sliver: SliverToBoxAdapter(
            child: Card(
              color: _automaticProfileSelection
                  ? YurichMobileColors.blueTint
                  : null,
              child: ListTile(
                key: const ValueKey('mobile-auto-server'),
                leading: const Icon(Icons.auto_awesome_rounded),
                title: Text(s.automaticServer),
                subtitle: Text(s.automaticServerHint),
                trailing: _automaticProfileSelection
                    ? const Icon(Icons.check_rounded)
                    : null,
                selected: _automaticProfileSelection,
                onTap: profiles.isEmpty || _preparingAutoConnect || _busy
                    ? null
                    : () {
                        _navigateMobile(_MobilePage.home);
                        unawaited(_chooseAutomaticMode());
                      },
              ),
            ),
          ),
        ),
        if (profiles.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            sliver: SliverToBoxAdapter(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(s.emptyProfiles),
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            sliver: SliverList.builder(
              itemCount: profiles.length,
              itemBuilder: (context, index) {
                final profile = profiles[index];
                final canCheck =
                    !ProtocolTestMetadata.isOfflineMarked(profile) &&
                    ((canProbe &&
                            (!ServerProbeTarget.usesUdp(profile) ||
                                active?.id == profile.id)) ||
                        (canDirect && DirectLatencyProbe.eligible(profile)));
                return Padding(
                  key: ValueKey(profile.id),
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _MobileServerTile(
                    key: ValueKey('mobile-server-${profile.id}'),
                    strings: s,
                    name: _mobileName(profile),
                    location: _profileCountryName(profile),
                    flag: _profileCountryFlag(profile),
                    latency: _mobileLatency(profile),
                    selected: profile.id == selectedId,
                    active: profile.id == active?.id,
                    onDetails: () =>
                        unawaited(_showMobileServerDetails(context, profile)),
                    onSelect: (_busy && !_connectionQueueActive)
                        ? null
                        : () {
                            _navigateMobile(_MobilePage.home);
                            unawaited(_selectProfile(profile));
                          },
                    onCheck: canCheck
                        ? () => unawaited(_checkMobileLatency([profile]))
                        : null,
                    onDelete: _busy || _preparingAutoConnect
                        ? null
                        : () => unawaited(_deleteProfile(profile)),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _mobileSettings(VpnProfile? profile) {
    final ready =
        !_busy &&
        !_connectionQueueActive &&
        !_smartRouteSettingsBusy &&
        !_preparingAutoConnect;
    final paused = _smartRoutePausedByKillSwitch;
    final warpDns =
        profile?.kind == VpnProfileKind.hysteria ||
        profile?.kind == VpnProfileKind.hysteria2;
    return ListView(
      key: const PageStorageKey('mobile-settings-scroll'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      children: [
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              SwitchListTile.adaptive(
                key: const ValueKey('mobile-smart-route'),
                secondary: const Icon(Icons.alt_route_rounded),
                title: Text(s.smartRouteLabel),
                subtitle: Text(
                  paused
                      ? s.smartRoutePaused
                      : _smartRouteRuDirect
                      ? s.smartRouteEnabledValue
                      : s.smartRouteDisabledValue,
                ),
                value: _smartRouteRuDirect,
                onChanged: ready && !paused && _smartRoutePreferenceLoaded
                    ? (enabled) => unawaited(_setSmartRouteRuDirect(enabled))
                    : null,
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              SwitchListTile.adaptive(
                key: const ValueKey('mobile-direct-latency'),
                secondary: const Icon(Icons.speed_outlined),
                title: Text(s.directLatencySetting),
                subtitle: Text(s.directLatencySubtitle),
                value: _directLatencyAllowed == true,
                onChanged:
                    ready &&
                        !kIsWeb &&
                        defaultTargetPlatform == TargetPlatform.android
                    ? (enabled) => unawaited(_changeDirectLatency(enabled))
                    : null,
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.apps_rounded),
                title: Text(s.appsDirect),
                subtitle: Text(s.appsDirectHint),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: ready && _smartRoutePreferenceLoaded
                    ? () => unawaited(_editSmartRouteApps())
                    : null,
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              if (warpDns)
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(s.dnsLabel),
                  subtitle: Text(s.dnsWarpValue),
                )
              else
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.dns_outlined),
                  title: Text(s.dnsLabel),
                  subtitle: Text(
                    _dnsProtectionMode.protectsAgainstLeaks
                        ? s.dnsLeakGuardValue
                        : s.dnsCountryValue,
                  ),
                  value: _dnsProtectionMode.protectsAgainstLeaks,
                  onChanged: ready
                      ? (enabled) => unawaited(_setDnsLeakProtection(enabled))
                      : null,
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_powerManagerService.supported) ...[
          Card(
            child: ListTile(
              key: const ValueKey('mobile-background-power'),
              leading: const Icon(Icons.battery_saver_outlined),
              title: Text(s.batterySettingsTitle),
              subtitle: Text(
                s.batterySettingsHint(_batteryOptimizationIgnored),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => unawaited(_openBackgroundPowerSettings()),
            ),
          ),
          const SizedBox(height: 12),
        ],
        KillSwitchPanel(
          state: _killSwitchState,
          russian: _language == _AppLanguage.ru,
          busy: _busy,
          onSettings: () => unawaited(_openKillSwitchSettings()),
          onRefresh: () =>
              unawaited(_refreshKillSwitchState(applyIfNeeded: true)),
          onApply: () => unawaited(_applyKillSwitchRoutes()),
          onNormal: () => unawaited(_useNormalKillSwitchRoutes()),
        ),
        const SizedBox(height: 12),
        if (_localIncidents.available) ...[
          Card(
            child: SwitchListTile.adaptive(
              key: const ValueKey('mobile-local-incidents'),
              secondary: const Icon(Icons.history_rounded),
              title: Text(s.localIncidentTitle),
              subtitle: Text(s.localIncidentSummary(_localIncidentState)),
              value: _localIncidentState.enabled,
              onChanged: _localIncidentSettingsBusy
                  ? null
                  : (enabled) =>
                        unawaited(_changeLocalIncidentConsent(enabled)),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (_localIncidents.hermesPreviewAvailable) ...[
          Card(
            child: ListTile(
              key: const ValueKey('mobile-hermes-preview'),
              leading: const Icon(Icons.preview_outlined),
              title: Text(s.hermesPreviewTitle),
              subtitle: Text(_hermesPreviewDescription),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => unawaited(_showHermesPreview()),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (_localIncidents.hermesDeliveryAvailable) ...[
          Card(
            child: ListTile(
              key: const ValueKey('mobile-hermes-delivery'),
              leading: const Icon(Icons.lock_outline_rounded),
              title: Text(
                _language == _AppLanguage.ru
                    ? 'Отправка отчётов Yurich'
                    : 'Send Yurich reports',
              ),
              subtitle: Text(
                _language == _AppLanguage.ru
                    ? 'Отдельное разрешение · только через проверенный VPN'
                    : 'Separate permission · verified VPN only',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => unawaited(_showHermesSendSettings()),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (_lastVpnFailureCategory != null) ...[
          Card(
            child: ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: Text(s.lastVpnFailure),
              subtitle: Text(s.vpnFailureMessage(_lastVpnFailureCategory)),
              trailing: IconButton(
                tooltip: s.report,
                onPressed: () => unawaited(_emailDeveloper()),
                icon: const Icon(Icons.description_outlined),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        _MobileSettingsSection(
          title: s.appSettings,
          subtitle: s.appSettingsSubtitle,
          onExpansionChanged: (expanded) {
            if (!expanded && _logsExpanded) unawaited(_setLogsExpanded(false));
          },
          child: _AppCenterPanel(
            strings: s,
            selectedTab: _supportTab,
            onTabChanged: _changeMobileSupportTab,
            language: _language,
            onLanguageChanged: (language) => unawaited(_setLanguage(language)),
            onSupport: () => _openUrl(_telegramUrl),
            onTelegram: () => _openUrl(_telegramUrl),
            onVk: () => _openUrl(_vkUrl),
            onDonate: () => _openUrl(_donateUrl),
            onDeveloper: _emailDeveloper,
            currentVersion: _appVersion,
            distributionChannel: _distributionChannel,
            availableVersion: _availableUpdate?.version,
            updateMessage: _updateMessage,
            updateBusy: _updateBusy,
            updateProgress: _updateProgress,
            onCheck: _checkAndInstallUpdate,
            logs: _logs,
            logsExpanded: _logsExpanded,
            onExpansionChanged: (expanded) =>
                unawaited(_setLogsExpanded(expanded)),
          ),
        ),
      ],
    );
  }
}

class _MobileSettingsSection extends StatelessWidget {
  const _MobileSettingsSection({
    required this.title,
    required this.subtitle,
    required this.child,
    this.onExpansionChanged,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final ValueChanged<bool>? onExpansionChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: const PageStorageKey('mobile-app-settings-expanded'),
        leading: const _AppSettingIcon(Icons.tune_rounded),
        title: Text(title, style: Theme.of(context).textTheme.titleMedium),
        subtitle: Text(subtitle),
        minTileHeight: 72,
        shape: const Border(),
        collapsedShape: const Border(),
        onExpansionChanged: onExpansionChanged,
        children: [child],
      ),
    );
  }
}

class _MobileImportDialog extends StatelessWidget {
  const _MobileImportDialog({
    required this.controller,
    required this.strings,
    required this.enabled,
  });

  final TextEditingController controller;
  final _Strings strings;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    void choose(_MobileImportAction action) =>
        Navigator.of(context).pop(action);

    return Dialog(
      key: const ValueKey('mobile-subscription-dialog'),
      backgroundColor: theme.scaffoldBackgroundColor,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      constraints: const BoxConstraints(maxWidth: 440),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    namesRoute: true,
                    child: Text(
                      strings.addSubscription,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: strings.close,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            Text(
              strings.subscriptionImportDescription,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('mobile-subscription-input'),
              controller: controller,
              enabled: enabled,
              minLines: 2,
              maxLines: 5,
              keyboardType: TextInputType.multiline,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              autofillHints: null,
              spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
              decoration: InputDecoration(
                labelText: strings.subscriptionInputLabel,
                hintText: strings.importHint,
                alignLabelWithHint: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(YurichRadii.control),
                ),
              ),
            ),
            const SizedBox(height: 14),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) => FilledButton(
                key: const ValueKey('mobile-subscription-submit'),
                onPressed: enabled && value.text.trim().isNotEmpty
                    ? () => choose(_MobileImportAction.input)
                    : null,
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                child: Text(strings.importAction),
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              alignment: WrapAlignment.center,
              children: [
                TextButton.icon(
                  key: const ValueKey('mobile-subscription-clipboard'),
                  onPressed: enabled
                      ? () => choose(_MobileImportAction.clipboard)
                      : null,
                  icon: const Icon(Icons.content_paste_rounded),
                  label: Text(strings.clipboard),
                ),
                TextButton.icon(
                  key: const ValueKey('mobile-subscription-qr'),
                  onPressed: enabled
                      ? () => choose(_MobileImportAction.qr)
                      : null,
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  label: Text(strings.scanQr),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileShell extends StatelessWidget {
  const _MobileShell({
    required this.page,
    required this.strings,
    required this.version,
    required this.serverCount,
    required this.serverActions,
    required this.onNavigate,
    required this.onImport,
    required this.child,
  });

  final _MobilePage page;
  final _Strings strings;
  final String version;
  final int serverCount;
  final List<Widget> serverActions;
  final ValueChanged<_MobilePage> onNavigate;
  final VoidCallback? onImport;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final home = page == _MobilePage.home;
    final settings = page == _MobilePage.settings;
    return PopScope(
      canPop: home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !home) onNavigate(_MobilePage.home);
      },
      child: Theme(
        data: YurichTheme.mobile,
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            leading: home
                ? null
                : BackButton(onPressed: () => onNavigate(_MobilePage.home)),
            title: home
                ? _MobileBrand(version: version)
                : Text(
                    settings
                        ? strings.settingsTab
                        : strings.serverPickerTitle(serverCount),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            actions: [
              ...serverActions,
              if (!settings)
                IconButton(
                  key: const ValueKey('mobile-import'),
                  tooltip: strings.addSubscription,
                  onPressed: onImport,
                  icon: const Icon(Icons.add_rounded),
                ),
            ],
          ),
          body: SafeArea(
            top: false,
            bottom: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: child,
              ),
            ),
          ),
          bottomNavigationBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (home)
                TextButton(
                  key: const ValueKey('mobile-quick-settings'),
                  onPressed: () => onNavigate(_MobilePage.settings),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    backgroundColor: YurichMobileColors.blueTint,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(18),
                      ),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: Text(strings.quickSettings)),
                      const SizedBox(width: 6),
                      const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
                    ],
                  ),
                ),
              const Divider(height: 1, color: YurichMobileColors.line),
              NavigationBar(
                height:
                    68 +
                    (MediaQuery.textScalerOf(context).scale(12) - 12)
                        .clamp(0, 36)
                        .toDouble(),
                selectedIndex: settings ? 1 : 0,
                onDestinationSelected: (index) => onNavigate(
                  index == 0 ? _MobilePage.home : _MobilePage.settings,
                ),
                destinations: [
                  NavigationDestination(
                    key: const ValueKey('mobile-home-tab'),
                    icon: const Icon(Icons.power_settings_new_rounded),
                    label: strings.homeTab,
                  ),
                  NavigationDestination(
                    key: const ValueKey('mobile-settings-tab'),
                    icon: const Icon(Icons.settings_outlined),
                    selectedIcon: const Icon(Icons.settings_rounded),
                    label: strings.settingsTab,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileBrand extends StatelessWidget {
  const _MobileBrand({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    final showVersion =
        MediaQuery.sizeOf(context).width >= 350 &&
        MediaQuery.textScalerOf(context).scale(12) <= 14;
    return Row(
      children: [
        const ClipRRect(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          child: Image(
            image: AssetImage('assets/images/app_icon.png'),
            width: 32,
            height: 32,
            excludeFromSemantics: true,
          ),
        ),
        const SizedBox(width: 10),
        const Flexible(
          child: Text(
            _appName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        if (showVersion) ...[
          const SizedBox(width: 8),
          Tooltip(
            message: version,
            child: _MobilePill(text: version.split('-').first),
          ),
        ],
      ],
    );
  }
}

class _MobileHome extends StatelessWidget {
  const _MobileHome({
    required this.emptyAction,
    required this.picker,
    required this.hero,
    required this.activeServer,
  });

  final Widget? emptyAction;
  final Widget picker;
  final Widget Function(double diameter) hero;
  final Widget? activeServer;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final enlarged = MediaQuery.textScalerOf(context).scale(16) > 20;
        final compact = enlarged || constraints.maxHeight < 475;
        final diameter = (constraints.maxWidth * 0.42)
            .clamp(126.0, 168.0)
            .toDouble();
        final topGap = compact
            ? 20.0
            : (constraints.maxHeight * (activeServer == null ? 0.38 : 0.28) -
                      60)
                  .clamp(20.0, 188.0)
                  .toDouble();
        final server = Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: activeServer,
        );
        return Stack(
          children: [
            const Positioned.fill(
              top: 54,
              bottom: 26,
              child: _MobileMapBackdrop(),
            ),
            CustomScrollView(
              key: const PageStorageKey('mobile-home-scroll'),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  sliver: SliverToBoxAdapter(child: picker),
                ),
                if (emptyAction != null)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    sliver: SliverToBoxAdapter(
                      child: Center(child: emptyAction),
                    ),
                  ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(16, topGap, 16, 16),
                  sliver: SliverToBoxAdapter(child: hero(diameter)),
                ),
                if (activeServer != null)
                  if (compact)
                    SliverToBoxAdapter(child: server)
                  else
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: server,
                      ),
                    ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _MobileMapBackdrop extends StatelessWidget {
  const _MobileMapBackdrop();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: Image.asset(
          'assets/images/mobile_world_map.png',
          fit: BoxFit.cover,
          opacity: const AlwaysStoppedAnimation<double>(0.69),
          cacheWidth: 900,
          excludeFromSemantics: true,
        ),
      ),
    );
  }
}

class _MobileServerPicker extends StatelessWidget {
  const _MobileServerPicker({
    required this.name,
    required this.flag,
    required this.strings,
    required this.refreshing,
    required this.onOpen,
    required this.onRefresh,
  });

  final String name;
  final String? flag;
  final _Strings strings;
  final bool refreshing;
  final VoidCallback onOpen;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: YurichMobileColors.paper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(YurichRadii.control),
        side: const BorderSide(color: YurichMobileColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          IconButton(
            tooltip: strings.refreshSubscriptions,
            onPressed: onRefresh,
            icon: refreshing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync_rounded, size: 22),
          ),
          const SizedBox(
            height: 26,
            child: VerticalDivider(width: 1, color: YurichMobileColors.line),
          ),
          Expanded(
            child: InkWell(
              key: const ValueKey('mobile-server-picker'),
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 32),
                  child: Row(
                    children: [
                      if (flag != null) ...[
                        ExcludeSemantics(
                          child: Text(
                            flag!,
                            textScaler: TextScaler.noScaling,
                            style: const TextStyle(
                              fontFamily: 'Noto Color Emoji',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(Icons.expand_more_rounded, size: 22),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileConnectionHero extends StatelessWidget {
  const _MobileConnectionHero({
    required this.diameter,
    required this.connection,
    required this.strings,
    required this.statusLabel,
    required this.action,
    required this.tone,
    required this.showTraffic,
    required this.notice,
    required this.latency,
    required this.onToggle,
  });

  final double diameter;
  final ConnectionUiState connection;
  final _Strings strings;
  final String statusLabel;
  final String action;
  final _MobilePowerTone tone;
  final bool showTraffic;
  final String? notice;
  final _MobileLatency? latency;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final (surface, rim, color, glow) = switch (tone) {
      _MobilePowerTone.active => (
        YurichMobileColors.powerActive,
        YurichMobileColors.powerActiveRing,
        YurichMobileColors.blue,
        YurichMobileColors.powerActiveHalo,
      ),
      _MobilePowerTone.problem => (
        YurichMobileColors.powerError,
        YurichMobileColors.powerErrorRing,
        YurichMobileColors.powerErrorInk,
        const Color(0x83F04763),
      ),
      _MobilePowerTone.pending => (
        YurichMobileColors.paper,
        YurichMobileColors.line,
        YurichMobileColors.warning,
        null,
      ),
      _MobilePowerTone.off => (
        YurichMobileColors.paper,
        YurichMobileColors.line,
        YurichMobileColors.ink,
        null,
      ),
    };
    return Column(
      children: [
        Semantics(
          label: action,
          button: true,
          enabled: onToggle != null,
          child: Tooltip(
            message: action,
            excludeFromSemantics: true,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  if (glow != null)
                    BoxShadow(
                      color: glow,
                      blurRadius: tone == _MobilePowerTone.active ? 39 : 35,
                      spreadRadius: tone == _MobilePowerTone.active ? 11 : 8,
                    ),
                  const BoxShadow(
                    color: Color(0x1E172033),
                    blurRadius: 20,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Material(
                animationDuration: Duration.zero,
                color: surface,
                shape: CircleBorder(
                  side: BorderSide(
                    color: rim,
                    width: tone == _MobilePowerTone.active
                        ? 4
                        : glow == null
                        ? 1
                        : 3,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: const ValueKey('mobile-vpn-power'),
                  onTap: onToggle,
                  customBorder: const CircleBorder(),
                  child: SizedBox.square(
                    dimension: diameter,
                    child: Icon(
                      Icons.power_settings_new_rounded,
                      color: onToggle == null && tone == _MobilePowerTone.off
                          ? YurichMobileColors.secondary
                          : color,
                      size: diameter * 0.42,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 22),
        Semantics(
          liveRegion: true,
          child: Text(
            statusLabel,
            key: const ValueKey('mobile-vpn-status'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: color,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (latency != null) ...[
          const SizedBox(height: 8),
          _MobilePill(
            icon: Icons.speed_outlined,
            text: latency!.label,
            tone: latency!.tone,
            key: const ValueKey('mobile-active-latency'),
          ),
        ],
        if (notice != null) ...[
          const SizedBox(height: 8),
          Text(
            notice!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (showTraffic) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 7,
            alignment: WrapAlignment.center,
            children: [
              _MobileMetric(
                icon: Icons.schedule_rounded,
                label: strings.durationLabel,
                value: connection.sessionDuration ?? '00:00',
              ),
              _MobileMetric(
                icon: Icons.arrow_upward_rounded,
                label: strings.uploadLabel,
                value: connection.uploadSpeed,
              ),
              _MobileMetric(
                icon: Icons.arrow_downward_rounded,
                label: strings.downloadLabel,
                value: connection.downloadSpeed,
              ),
              _MobileMetric(
                icon: Icons.data_usage_rounded,
                label: strings.trafficTotalLabel,
                value: connection.totalTraffic,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _MobilePill extends StatelessWidget {
  const _MobilePill({
    super.key,
    required this.text,
    this.icon,
    this.tone = _MobilePillTone.blue,
  });

  final String text;
  final IconData? icon;
  final _MobilePillTone tone;

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = switch (tone) {
      _MobilePillTone.blue => (
        YurichMobileColors.blueTint,
        YurichMobileColors.blue,
      ),
      _MobilePillTone.neutral => (
        const Color(0xFFEEF0F5),
        YurichMobileColors.secondary,
      ),
      _MobilePillTone.warning => (
        YurichMobileColors.warningTint,
        YurichMobileColors.warning,
      ),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: const BorderRadius.all(Radius.circular(30)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: foreground),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                text,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: foreground,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileMetric extends StatelessWidget {
  const _MobileMetric({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label: $value',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: YurichMobileColors.secondary),
          const SizedBox(width: 4),
          Text(
            value,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: YurichMobileColors.secondary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileFlag extends StatelessWidget {
  const _MobileFlag(this.flag, {this.size = 38});

  final String? flag;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: YurichMobileColors.blueTint,
          borderRadius: BorderRadius.all(Radius.circular(11)),
        ),
        child: flag == null
            ? Icon(Icons.public_rounded, size: size * 0.55)
            : Text(
                flag!,
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontSize: size * 0.60,
                  fontFamily: 'Noto Color Emoji',
                ),
              ),
      ),
    );
  }
}

class _MobileActiveServer extends StatelessWidget {
  const _MobileActiveServer({
    required this.label,
    required this.location,
    required this.flag,
    required this.onTap,
  });

  final String label;
  final String location;
  final String? flag;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 256),
        child: Card(
          key: const ValueKey('mobile-active-server'),
          elevation: 1,
          shadowColor: const Color(0x25172033),
          clipBehavior: Clip.antiAlias,
          child: Semantics(
            label: '$label: $location',
            button: true,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 32),
                  child: ExcludeSemantics(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _MobileFlag(flag, size: 28),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            location,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.titleSmall,
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.chevron_right_rounded, size: 18),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileServerTile extends StatelessWidget {
  const _MobileServerTile({
    super.key,
    required this.strings,
    required this.name,
    required this.location,
    required this.flag,
    required this.latency,
    required this.selected,
    required this.active,
    required this.onSelect,
    required this.onDetails,
    required this.onCheck,
    required this.onDelete,
  });

  final _Strings strings;
  final String name;
  final String? location;
  final String? flag;
  final _MobileLatency latency;
  final bool selected;
  final bool active;
  final VoidCallback? onSelect;
  final VoidCallback onDetails;
  final VoidCallback? onCheck;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      color: selected ? YurichMobileColors.blueTint : null,
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              selected: selected,
              label: location,
              child: InkWell(
                onTap: onSelect,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 9, 0, 9),
                  child: Row(
                    children: [
                      _MobileFlag(flag),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    name,
                                    style: text.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (active) ...[
                                  const SizedBox(width: 6),
                                  Tooltip(
                                    message: strings.activeProfile,
                                    child: const Icon(
                                      Icons.check_circle_rounded,
                                      size: 16,
                                      color: YurichMobileColors.blue,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 3),
                            _MobilePill(
                              text: latency.label,
                              tone: latency.tone,
                              icon: Icons.speed_outlined,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          PopupMenuButton<_MobileServerAction>(
            tooltip: '${strings.moreServerActions}: $name',
            onSelected: (action) {
              switch (action) {
                case _MobileServerAction.details:
                  onDetails();
                case _MobileServerAction.check:
                  onCheck?.call();
                case _MobileServerAction.delete:
                  onDelete?.call();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: _MobileServerAction.details,
                child: Text(strings.serverDetails),
              ),
              PopupMenuItem(
                value: _MobileServerAction.check,
                enabled: onCheck != null,
                child: Text(strings.refreshServer),
              ),
              PopupMenuItem(
                value: _MobileServerAction.delete,
                enabled: onDelete != null,
                child: Text(strings.delete),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
