part of 'home_screen.dart';

class _AppBarGradient extends StatelessWidget {
  const _AppBarGradient();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(gradient: YurichGradients.header),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.pulse,
    required this.strings,
    required this.status,
    required this.connectionState,
    required this.degraded,
    required this.message,
    required this.uplink,
    required this.downlink,
    required this.uptime,
    required this.total,
    required this.onToggle,
    required this.toggleEnabled,
  });

  final Animation<double> pulse;
  final _Strings strings;
  final String status;
  final ConnectionUiState connectionState;
  final bool degraded;
  final String message;
  final String uplink;
  final String downlink;
  final String uptime;
  final String total;
  final VoidCallback onToggle;
  final bool toggleEnabled;

  @override
  Widget build(BuildContext context) {
    final connected = status == AurumVpnStatus.started;
    final statusLabel = switch (connectionState.status) {
      ConnectionStatus.connected => strings.connected,
      ConnectionStatus.idle => strings.idleConnection,
      ConnectionStatus.networkChanging => strings.reconnectingConnection,
      ConnectionStatus.degraded => strings.connectionProblem,
      ConnectionStatus.reconnecting => strings.reconnectingConnection,
      ConnectionStatus.failed => strings.connectionProblem,
      ConnectionStatus.connecting =>
        status == AurumVpnStatus.stopping
            ? strings.disconnecting
            : strings.connecting,
      ConnectionStatus.disconnected => strings.stopped,
    };
    final accent = degraded
        ? _danger
        : connected
        ? _cyanGlow
        : YurichColors.border;
    final glow = degraded
        ? _danger.withValues(alpha: 0.22)
        : connected
        ? _cyanGlow.withValues(alpha: 0.18)
        : YurichColors.shadow;
    final protocol = connectionState.protocolDisplayName ?? '—';
    final country = [
      connectionState.countryName,
      connectionState.countryCode == null
          ? null
          : ProfileGeo.countryCodeToFlag(connectionState.countryCode),
    ].whereType<String>().where((value) => value.isNotEmpty).join(' ');
    final ping = connectionState.pingMs == null
        ? '—'
        : '${connectionState.pingMs} ms';

    return AnimatedBuilder(
      animation: pulse,
      builder: (context, child) {
        final glowPower = connected || degraded ? pulse.value : 0.0;
        return SizedBox(
          height: 196,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: degraded
                  ? YurichGradients.errorCard
                  : connected
                  ? YurichGradients.activeCard
                  : YurichGradients.inactiveCard,
              borderRadius: BorderRadius.circular(YurichRadii.card),
              border: Border.all(
                color: connected || degraded
                    ? accent.withValues(alpha: 0.74 + glowPower * 0.26)
                    : accent,
              ),
              boxShadow: [
                BoxShadow(
                  color: glow.withValues(alpha: 0.14 + glowPower * 0.24),
                  blurRadius: 18 + glowPower * 18,
                  spreadRadius: glowPower * 1.4,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: child,
            ),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                degraded
                    ? Icons.warning_amber_rounded
                    : connected
                    ? Icons.verified_user
                    : Icons.shield_outlined,
                color: degraded
                    ? _dangerSoft
                    : connected
                    ? _goldSoft
                    : _mutedGold,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  statusLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            message,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _mutedGold),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _StatusInfoPill(
                  icon: Icons.route_outlined,
                  text: protocol,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatusInfoPill(
                  icon: Icons.flag_outlined,
                  text: country.isEmpty ? '—' : country,
                ),
              ),
              const SizedBox(width: 8),
              _StatusInfoPill(icon: Icons.speed_outlined, text: ping),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: _Metric(label: '↑', value: uplink, fixed: true),
              ),
              const SizedBox(width: 14),
              _UptimeButton(
                pulse: pulse,
                connected: connected,
                degraded: degraded,
                uptime: uptime,
                total: total,
                enabled: toggleEnabled,
                onPressed: onToggle,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _Metric(label: '↓', value: downlink, fixed: true),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _UptimeButton extends StatelessWidget {
  const _UptimeButton({
    required this.pulse,
    required this.connected,
    required this.degraded,
    required this.uptime,
    required this.total,
    required this.enabled,
    required this.onPressed,
  });

  final Animation<double> pulse;
  final bool connected;
  final bool degraded;
  final String uptime;
  final String total;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, child) {
        final glowPower = connected || degraded ? pulse.value : 0.0;
        return Transform.scale(
          scale: connected || degraded ? 1 + glowPower * 0.025 : 1,
          child: Tooltip(
            message: connected ? 'Время работы VPN' : 'Подключить',
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: connected
                      ? degraded
                            ? YurichGradients.dangerButton
                            : YurichGradients.cyanButton
                      : YurichGradients.idleButton,
                  border: Border.all(
                    color: degraded
                        ? YurichColors.dangerSoft
                        : connected
                        ? YurichColors.accentSoft
                        : _gold.withValues(alpha: 0.35),
                    width: connected ? 2.2 : 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: degraded
                          ? _danger.withValues(alpha: 0.42 + glowPower * 0.28)
                          : connected
                          ? _cyanGlow.withValues(alpha: 0.42 + glowPower * 0.3)
                          : YurichColors.shadow.withValues(alpha: 0.55),
                      blurRadius: connected ? 22 + glowPower * 12 : 14,
                      spreadRadius: (connected || degraded)
                          ? 1.4 + glowPower
                          : 0.8,
                      offset: Offset.zero,
                    ),
                  ],
                ),
                child: child,
              ),
            ),
          ),
        );
      },
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onPressed : null,
        child: SizedBox.square(
          dimension: 82,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  degraded
                      ? Icons.priority_high_rounded
                      : connected
                      ? Icons.timer_outlined
                      : Icons.power_settings_new,
                  color: connected ? _ink : _goldSoft,
                  size: 21,
                ),
                const SizedBox(height: 3),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    connected ? uptime : '00:00',
                    maxLines: 1,
                    style: TextStyle(
                      color: connected ? _ink : _goldSoft,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      letterSpacing: 0,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    total,
                    maxLines: 1,
                    style: TextStyle(
                      color: connected
                          ? _ink.withValues(alpha: 0.66)
                          : _mutedGold,
                      fontWeight: FontWeight.w600,
                      fontSize: 10,
                      letterSpacing: 0,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusInfoPill extends StatelessWidget {
  const _StatusInfoPill({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: YurichColors.surfaceMetric.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(YurichRadii.control),
        border: Border.all(color: YurichColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: YurichColors.textSecondary),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: YurichColors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.fixed = false});

  final String label;
  final String value;
  final bool fixed;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      '$label $value',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(letterSpacing: 0),
    );

    return Container(
      height: fixed ? 52 : null,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        gradient: YurichGradients.metric,
        borderRadius: BorderRadius.circular(YurichRadii.control),
        border: Border.all(color: YurichColors.border),
      ),
      alignment: Alignment.center,
      child: fixed
          ? FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: text,
            )
          : text,
    );
  }
}

class _ProfilePanel extends StatelessWidget {
  const _ProfilePanel({
    required this.pulse,
    required this.strings,
    required this.profiles,
    required this.selectedProfile,
    required this.selectedId,
    required this.activeProfileId,
    required this.selectedTab,
    required this.profilesExpanded,
    required this.onTabChanged,
    required this.onProfilesExpandedChanged,
    required this.onSelect,
    required this.onAdd,
    required this.onCopy,
    required this.onQr,
    required this.onDeleteProfile,
    required this.onRefreshSubscriptions,
    required this.hasSubscriptionSources,
    required this.subscriptionRefreshBusy,
    required this.subscriptionStatus,
    required this.subscriptionNeedsAttention,
    required this.batteryOptimizationIgnored,
    required this.smartRouteRuDirect,
    required this.dnsLeakProtectionEnabled,
    required this.keeperStatus,
    required this.idleKeeperStatus,
    required this.lastHealthStatus,
    required this.autoRecoveryStatus,
    required this.healthFailuresStatus,
    required this.stabilityNeedsAttention,
    required this.kindLabel,
    required this.displayName,
    required this.countryFlag,
    required this.pingLabel,
    required this.profileStabilityLabel,
    required this.onPingAll,
    required this.onPing,
    required this.onRequestBackgroundAccess,
    required this.onSmartRouteChanged,
    required this.onDnsLeakProtectionChanged,
  });

  final Animation<double> pulse;
  final _Strings strings;
  final List<VpnProfile> profiles;
  final VpnProfile? selectedProfile;
  final String? selectedId;
  final String? activeProfileId;
  final _ProfileTab selectedTab;
  final bool profilesExpanded;
  final ValueChanged<_ProfileTab> onTabChanged;
  final ValueChanged<bool> onProfilesExpandedChanged;
  final ValueChanged<VpnProfile> onSelect;
  final VoidCallback onAdd;
  final VoidCallback? onCopy;
  final VoidCallback? onQr;
  final ValueChanged<VpnProfile> onDeleteProfile;
  final VoidCallback onRefreshSubscriptions;
  final bool hasSubscriptionSources;
  final bool subscriptionRefreshBusy;
  final String? Function(VpnProfile profile) subscriptionStatus;
  final bool Function(VpnProfile profile) subscriptionNeedsAttention;
  final bool batteryOptimizationIgnored;
  final bool smartRouteRuDirect;
  final bool dnsLeakProtectionEnabled;
  final String keeperStatus;
  final String idleKeeperStatus;
  final String lastHealthStatus;
  final String autoRecoveryStatus;
  final String healthFailuresStatus;
  final bool stabilityNeedsAttention;
  final String Function(VpnProfileKind kind) kindLabel;
  final String Function(VpnProfile profile) displayName;
  final String? Function(VpnProfile profile) countryFlag;
  final String Function(VpnProfile profile) pingLabel;
  final String Function(VpnProfile profile) profileStabilityLabel;
  final VoidCallback onPingAll;
  final ValueChanged<VpnProfile> onPing;
  final VoidCallback onRequestBackgroundAccess;
  final ValueChanged<bool> onSmartRouteChanged;
  final ValueChanged<bool> onDnsLeakProtectionChanged;

  @override
  Widget build(BuildContext context) {
    const compactProfileLimit = 6;
    final matchingProfiles = profiles
        .where((profile) => _profileMatchesTab(profile, selectedTab))
        .toList(growable: false);
    final visibleProfiles = [
      ...matchingProfiles.where((profile) => profile.id == selectedId),
      ...matchingProfiles.where((profile) => profile.id != selectedId),
    ];
    final shownProfiles = profilesExpanded
        ? visibleProfiles
        : visibleProfiles.take(compactProfileLimit).toList(growable: false);
    final hiddenProfiles = visibleProfiles.length - shownProfiles.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                strings.profiles,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: strings.refreshSubscriptions,
              onPressed: hasSubscriptionSources && !subscriptionRefreshBusy
                  ? onRefreshSubscriptions
                  : null,
              icon: subscriptionRefreshBusy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
            ),
            IconButton(
              tooltip: strings.refreshPing,
              onPressed: profiles.isEmpty ? null : onPingAll,
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: strings.addProfile,
              onPressed: onAdd,
              icon: const Icon(Icons.add_link),
            ),
            IconButton(
              tooltip: strings.showQr,
              onPressed: onQr,
              icon: const Icon(Icons.qr_code_2),
            ),
            IconButton(
              tooltip: strings.copy,
              onPressed: onCopy,
              icon: const Icon(Icons.copy),
            ),
          ],
        ),
        if (profiles.isEmpty)
          _EmptyProfiles(strings: strings)
        else ...[
          const SizedBox(height: 8),
          _ServerPickerSummary(
            strings: strings,
            selectedProfile: selectedProfile,
            totalCount: profiles.length,
            visibleCount: visibleProfiles.length,
            profilesExpanded: profilesExpanded,
            onToggle: () => onProfilesExpandedChanged(!profilesExpanded),
            kindLabel: kindLabel,
            displayName: displayName,
            countryFlag: countryFlag,
            pingLabel: pingLabel,
          ),
          if (profilesExpanded) ...[
            const SizedBox(height: 10),
            _ProfileTabBar(
              pulse: pulse,
              strings: strings,
              profiles: profiles,
              selectedTab: selectedTab,
              onChanged: onTabChanged,
            ),
            const SizedBox(height: 10),
            if (visibleProfiles.isEmpty)
              _EmptyProfiles(message: strings.noProfilesInTab(selectedTab))
            else ...[
              ...shownProfiles.map(
                (profile) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _ProfileTile(
                    pulse: pulse,
                    profile: profile,
                    selected: profile.id == selectedId,
                    active: profile.id == activeProfileId,
                    onTap: () => onSelect(profile),
                    kindLabel: kindLabel,
                    displayName: displayName(profile),
                    countryFlag: countryFlag(profile),
                    pingLabel: pingLabel(profile),
                    subscriptionStatus: subscriptionStatus(profile),
                    subscriptionNeedsAttention: subscriptionNeedsAttention(
                      profile,
                    ),
                    subscriptionLabel: strings.subscriptionLabel,
                    activeLabel: strings.activeProfile,
                    onPing: () => onPing(profile),
                    onDelete: () => onDeleteProfile(profile),
                    deleteTooltip: strings.delete,
                  ),
                ),
              ),
              if (hiddenProfiles > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 10),
                  child: Center(
                    child: TextButton.icon(
                      onPressed: () => onProfilesExpandedChanged(true),
                      icon: const Icon(Icons.unfold_more),
                      label: Text(strings.showMoreProfiles(hiddenProfiles)),
                    ),
                  ),
                ),
            ],
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 8),
              child: Center(
                child: TextButton.icon(
                  onPressed: () => onProfilesExpandedChanged(false),
                  icon: const Icon(Icons.keyboard_arrow_up),
                  label: Text(strings.collapseProfiles),
                ),
              ),
            ),
          ],
        ],
        const SizedBox(height: 6),
        _ProfileInsightPanel(
          strings: strings,
          profile: selectedProfile,
          kindLabel: kindLabel,
          countryFlag: selectedProfile == null
              ? null
              : countryFlag(selectedProfile!),
          pingLabel: selectedProfile == null
              ? null
              : pingLabel(selectedProfile!),
          subscriptionStatus: selectedProfile == null
              ? null
              : strings.subscriptionStatus(
                  selectedProfile!.subscriptionExpiresAt,
                ),
          subscriptionNeedsAttention: selectedProfile == null
              ? false
              : subscriptionNeedsAttention(selectedProfile!),
          canRefreshSubscriptions: hasSubscriptionSources,
          subscriptionRefreshBusy: subscriptionRefreshBusy,
          batteryOptimizationIgnored: batteryOptimizationIgnored,
          smartRouteRuDirect: smartRouteRuDirect,
          dnsLeakProtectionEnabled: dnsLeakProtectionEnabled,
          keeperStatus: keeperStatus,
          idleKeeperStatus: idleKeeperStatus,
          lastHealthStatus: lastHealthStatus,
          autoRecoveryStatus: autoRecoveryStatus,
          healthFailuresStatus: healthFailuresStatus,
          stabilityNeedsAttention: stabilityNeedsAttention,
          profileStabilityStatus: selectedProfile == null
              ? null
              : profileStabilityLabel(selectedProfile!),
          onRefreshSubscriptions: onRefreshSubscriptions,
          onRequestBackgroundAccess: onRequestBackgroundAccess,
          onSmartRouteChanged: onSmartRouteChanged,
          onDnsLeakProtectionChanged: onDnsLeakProtectionChanged,
          onPing: selectedProfile == null
              ? null
              : () => onPing(selectedProfile!),
        ),
      ],
    );
  }
}

class _ServerPickerSummary extends StatelessWidget {
  const _ServerPickerSummary({
    required this.strings,
    required this.selectedProfile,
    required this.totalCount,
    required this.visibleCount,
    required this.profilesExpanded,
    required this.onToggle,
    required this.kindLabel,
    required this.displayName,
    required this.countryFlag,
    required this.pingLabel,
  });

  final _Strings strings;
  final VpnProfile? selectedProfile;
  final int totalCount;
  final int visibleCount;
  final bool profilesExpanded;
  final VoidCallback onToggle;
  final String Function(VpnProfileKind kind) kindLabel;
  final String Function(VpnProfile profile) displayName;
  final String? Function(VpnProfile profile) countryFlag;
  final String Function(VpnProfile profile) pingLabel;

  @override
  Widget build(BuildContext context) {
    final profile = selectedProfile;
    final title = profile == null
        ? strings.serverPickerEmpty
        : displayName(profile);
    final flag = profile == null ? null : countryFlag(profile);
    final details = profile == null
        ? strings.autoConnectMode
        : [
            if (flag != null && flag.isNotEmpty) flag,
            kindLabel(profile.kind),
            profile.endpoint,
            pingLabel(profile),
          ].where((value) => value.trim().isNotEmpty).join(' · ');

    return InkWell(
      borderRadius: BorderRadius.circular(YurichRadii.card),
      onTap: onToggle,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: YurichGradients.compactCard,
          borderRadius: BorderRadius.circular(YurichRadii.card),
          border: Border.all(color: _cyanGlow.withValues(alpha: 0.34)),
          boxShadow: [
            BoxShadow(
              color: _cyanGlow.withValues(alpha: 0.08),
              blurRadius: 18,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _cyanGlow.withValues(alpha: 0.14),
                  border: Border.all(color: _cyanGlow.withValues(alpha: 0.38)),
                ),
                child: const Icon(Icons.storage_rounded),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      strings.serverPickerTitle(totalCount),
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: _mutedGold,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: _mutedGold),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    profilesExpanded
                        ? strings.hideServers
                        : strings.openServers,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: _cyanGlow,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    strings.visibleServers(visibleCount),
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: _mutedGold),
                  ),
                ],
              ),
              const SizedBox(width: 4),
              Icon(
                profilesExpanded
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
                color: _cyanGlow,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileTabBar extends StatelessWidget {
  const _ProfileTabBar({
    required this.pulse,
    required this.strings,
    required this.profiles,
    required this.selectedTab,
    required this.onChanged,
  });

  final Animation<double> pulse;
  final _Strings strings;
  final List<VpnProfile> profiles;
  final _ProfileTab selectedTab;
  final ValueChanged<_ProfileTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final tab in _ProfileTab.values) ...[
            AnimatedBuilder(
              animation: pulse,
              builder: (context, child) {
                final selected = selectedTab == tab;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(YurichRadii.chip),
                    boxShadow: selected
                        ? [
                            BoxShadow(
                              color: _cyanGlow.withValues(
                                alpha: 0.24 + pulse.value * 0.22,
                              ),
                              blurRadius: 16 + pulse.value * 12,
                              spreadRadius: 1 + pulse.value,
                            ),
                          ]
                        : null,
                  ),
                  child: child,
                );
              },
              child: ChoiceChip(
                label: Text(strings.profileTabLabel(tab, _countFor(tab))),
                selected: selectedTab == tab,
                showCheckmark: false,
                onSelected: (_) => onChanged(tab),
                selectedColor: _cyanGlow,
                backgroundColor: _surfaceMetric,
                surfaceTintColor: Colors.transparent,
                labelStyle: TextStyle(
                  color: selectedTab == tab ? _ink : _goldSoft,
                  fontWeight: selectedTab == tab
                      ? FontWeight.w900
                      : FontWeight.w700,
                  letterSpacing: 0,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(YurichRadii.chip),
                  side: BorderSide(
                    color: selectedTab == tab
                        ? _goldSoft.withValues(alpha: 0.95)
                        : _gold.withValues(alpha: 0.2),
                    width: selectedTab == tab ? 1.4 : 1,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  int _countFor(_ProfileTab tab) {
    if (tab == _ProfileTab.all) {
      return profiles.length;
    }
    return profiles.where((profile) => _profileMatchesTab(profile, tab)).length;
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.pulse,
    required this.profile,
    required this.selected,
    required this.active,
    required this.onTap,
    required this.kindLabel,
    required this.displayName,
    required this.countryFlag,
    required this.pingLabel,
    required this.subscriptionStatus,
    required this.subscriptionNeedsAttention,
    required this.subscriptionLabel,
    required this.activeLabel,
    required this.onPing,
    required this.onDelete,
    required this.deleteTooltip,
  });

  final Animation<double> pulse;
  final VpnProfile profile;
  final bool selected;
  final bool active;
  final VoidCallback onTap;
  final String Function(VpnProfileKind kind) kindLabel;
  final String displayName;
  final String? countryFlag;
  final String pingLabel;
  final String? subscriptionStatus;
  final bool subscriptionNeedsAttention;
  final String subscriptionLabel;
  final String activeLabel;
  final VoidCallback onPing;
  final VoidCallback onDelete;
  final String deleteTooltip;

  @override
  Widget build(BuildContext context) {
    final content = Row(
      children: [
        SizedBox(
          width: 32,
          child: Center(
            child: countryFlag == null
                ? Icon(switch (profile.kind) {
                    VpnProfileKind.naive => Icons.public,
                    VpnProfileKind.hysteria2 ||
                    VpnProfileKind.hysteria => Icons.speed_outlined,
                    VpnProfileKind.pingTunnelExperimental =>
                      Icons.radar_outlined,
                    _ => Icons.bolt,
                  }, color: selected ? _goldSoft : _mutedGold)
                : Text(countryFlag!, style: const TextStyle(fontSize: 22)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: selected ? YurichColors.textPrimary : null,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${kindLabel(profile.kind)} · ${profile.endpoint}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _mutedGold),
              ),
              if (subscriptionStatus != null) ...[
                const SizedBox(height: 4),
                Text(
                  '$subscriptionLabel · $subscriptionStatus',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: subscriptionNeedsAttention
                        ? _dangerSoft
                        : _mutedGold,
                    fontSize: 12,
                    fontWeight: subscriptionNeedsAttention
                        ? FontWeight.w700
                        : FontWeight.w400,
                    letterSpacing: 0,
                  ),
                ),
              ],
              if (active) ...[
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: YurichGradients.activeBadge,
                        borderRadius: BorderRadius.circular(999),
                        boxShadow: [
                          BoxShadow(
                            color: _cyanGlow.withValues(alpha: 0.28),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        child: Text(
                          activeLabel,
                          maxLines: 1,
                          style: const TextStyle(
                            color: _ink,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        InkResponse(
          onTap: onPing,
          radius: 28,
          child: Container(
            constraints: const BoxConstraints(minWidth: 64),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: _surfaceMetric,
              borderRadius: BorderRadius.circular(YurichRadii.chip),
              border: Border.all(color: YurichColors.border),
            ),
            alignment: Alignment.center,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                pingLabel,
                maxLines: 1,
                style: const TextStyle(
                  color: _goldSoft,
                  fontSize: 12,
                  letterSpacing: 0,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: deleteTooltip,
          onPressed: onDelete,
          icon: const Icon(Icons.delete_outline),
          color: selected ? _goldSoft : _mutedGold,
          iconSize: 20,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );

    return AnimatedBuilder(
      animation: pulse,
      builder: (context, child) {
        final glowPower = selected || active ? pulse.value : 0.0;
        final borderColor = active
            ? _cyanGlow.withValues(alpha: 0.98)
            : selected
            ? _goldSoft.withValues(alpha: 0.92)
            : YurichColors.border;
        return InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(YurichRadii.panel),
          child: Ink(
            decoration: BoxDecoration(
              gradient: selected
                  ? YurichGradients.selectedProfile
                  : YurichGradients.inactiveCard,
              borderRadius: BorderRadius.circular(YurichRadii.panel),
              border: Border.all(
                color: borderColor,
                width: selected || active ? 2 : 1,
              ),
              boxShadow: selected || active
                  ? [
                      BoxShadow(
                        color: (active ? _cyanGlow : _gold).withValues(
                          alpha: 0.22 + glowPower * 0.2,
                        ),
                        blurRadius: 22 + glowPower * 16,
                        spreadRadius: 1 + glowPower * 1.5,
                        offset: const Offset(0, 7),
                      ),
                    ]
                  : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(YurichRadii.panel - 2),
              child: Stack(
                children: [
                  if (selected || active)
                    Positioned.fill(
                      left: 0,
                      right: null,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: active
                                ? YurichGradients.activeBadge.colors
                                : const [
                                    YurichColors.accentSoft,
                                    YurichColors.accentCyan,
                                  ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: _cyanGlow.withValues(alpha: 0.5),
                              blurRadius: 12,
                            ),
                          ],
                        ),
                        child: const SizedBox(width: 5),
                      ),
                    ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      selected || active ? 18 : 14,
                      14,
                      14,
                      14,
                    ),
                    child: child,
                  ),
                ],
              ),
            ),
          ),
        );
      },
      child: content,
    );
  }
}

class _EmptyProfiles extends StatelessWidget {
  const _EmptyProfiles({this.strings, this.message});

  final _Strings? strings;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: YurichColors.surface,
        borderRadius: BorderRadius.circular(YurichRadii.panel),
        border: Border.all(color: YurichColors.border),
      ),
      child: Text(message ?? strings!.emptyProfiles),
    );
  }
}

class _ProfileInsightPanel extends StatelessWidget {
  const _ProfileInsightPanel({
    required this.strings,
    required this.profile,
    required this.kindLabel,
    required this.countryFlag,
    required this.pingLabel,
    required this.subscriptionStatus,
    required this.subscriptionNeedsAttention,
    required this.canRefreshSubscriptions,
    required this.subscriptionRefreshBusy,
    required this.batteryOptimizationIgnored,
    required this.smartRouteRuDirect,
    required this.dnsLeakProtectionEnabled,
    required this.keeperStatus,
    required this.idleKeeperStatus,
    required this.lastHealthStatus,
    required this.autoRecoveryStatus,
    required this.healthFailuresStatus,
    required this.stabilityNeedsAttention,
    required this.profileStabilityStatus,
    required this.onRefreshSubscriptions,
    required this.onRequestBackgroundAccess,
    required this.onSmartRouteChanged,
    required this.onDnsLeakProtectionChanged,
    required this.onPing,
  });

  final _Strings strings;
  final VpnProfile? profile;
  final String Function(VpnProfileKind kind) kindLabel;
  final String? countryFlag;
  final String? pingLabel;
  final String? subscriptionStatus;
  final bool subscriptionNeedsAttention;
  final bool canRefreshSubscriptions;
  final bool subscriptionRefreshBusy;
  final bool batteryOptimizationIgnored;
  final bool smartRouteRuDirect;
  final bool dnsLeakProtectionEnabled;
  final String keeperStatus;
  final String idleKeeperStatus;
  final String lastHealthStatus;
  final String autoRecoveryStatus;
  final String healthFailuresStatus;
  final bool stabilityNeedsAttention;
  final String? profileStabilityStatus;
  final VoidCallback onRefreshSubscriptions;
  final VoidCallback onRequestBackgroundAccess;
  final ValueChanged<bool> onSmartRouteChanged;
  final ValueChanged<bool> onDnsLeakProtectionChanged;
  final VoidCallback? onPing;

  @override
  Widget build(BuildContext context) {
    final selectedProfile = profile;
    final profileUsesWarpDns =
        selectedProfile != null && _usesWarpDns(selectedProfile);

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _surfaceMetric.withValues(alpha: 0.9),
            YurichColors.surfaceElevated.withValues(alpha: 0.88),
          ],
        ),
        borderRadius: BorderRadius.circular(YurichRadii.panel),
        border: Border.all(color: YurichColors.border),
        boxShadow: [
          BoxShadow(
            color: _deepGlow.withValues(alpha: 0.12),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.health_and_safety_outlined, color: _goldSoft),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    strings.profileInsight,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (profile == null)
              Text(
                strings.profileInsightEmpty,
                style: const TextStyle(color: _mutedGold),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    children: [
                      _InsightRow(
                        icon: Icons.route_outlined,
                        label: strings.protocolLabel,
                        value: kindLabel(profile!.kind),
                      ),
                      _InsightRow(
                        icon: Icons.network_cell_outlined,
                        label: strings.networkLabel,
                        value: strings.mobileReady,
                      ),
                      _InsightRow(
                        icon: Icons.hub_outlined,
                        label: strings.smartRouteLabel,
                        value: smartRouteRuDirect
                            ? strings.smartRouteEnabledValue
                            : strings.smartRouteDisabledValue,
                        trailing: Switch.adaptive(
                          value: smartRouteRuDirect,
                          onChanged: onSmartRouteChanged,
                          activeThumbColor: _cyanGlow,
                        ),
                        onTap: () => onSmartRouteChanged(!smartRouteRuDirect),
                      ),
                      _InsightRow(
                        icon: Icons.dns_outlined,
                        label: strings.dnsLabel,
                        value: profileUsesWarpDns
                            ? strings.dnsWarpValue
                            : dnsLeakProtectionEnabled
                            ? strings.dnsLeakGuardValue
                            : strings.dnsCountryValue,
                        trailing: profileUsesWarpDns
                            ? null
                            : Switch.adaptive(
                                value: dnsLeakProtectionEnabled,
                                onChanged: onDnsLeakProtectionChanged,
                                activeThumbColor: _cyanGlow,
                              ),
                        onTap: profileUsesWarpDns
                            ? null
                            : () => onDnsLeakProtectionChanged(
                                !dnsLeakProtectionEnabled,
                              ),
                      ),
                      _InsightRow(
                        icon: Icons.security_update_good_outlined,
                        label: strings.stabilityLabel,
                        value: stabilityNeedsAttention
                            ? strings.stabilityNeedsAttention
                            : strings.stabilityValue,
                        valueColor: stabilityNeedsAttention
                            ? _dangerSoft
                            : null,
                      ),
                      if (profileStabilityStatus != null)
                        _InsightRow(
                          icon: Icons.verified_outlined,
                          label: strings.profileStabilityLabel,
                          value: profileStabilityStatus!,
                          valueColor:
                              profileStabilityStatus ==
                                      strings.profileStabilityWeak ||
                                  profileStabilityStatus ==
                                      strings.profileStabilityCoolingDown
                              ? _dangerSoft
                              : null,
                        ),
                      _InsightRow(
                        icon: Icons.monitor_heart_outlined,
                        label: strings.keeperLabel,
                        value: keeperStatus,
                        valueColor: stabilityNeedsAttention
                            ? _dangerSoft
                            : null,
                      ),
                      _InsightRow(
                        icon: Icons.nightlight_round_outlined,
                        label: strings.idleKeeperLabel,
                        value: idleKeeperStatus,
                      ),
                      _InsightRow(
                        icon: Icons.schedule_outlined,
                        label: strings.lastCheckLabel,
                        value: lastHealthStatus,
                      ),
                      _InsightRow(
                        icon: Icons.restart_alt_outlined,
                        label: strings.autoRecoveryLabel,
                        value: autoRecoveryStatus,
                      ),
                      _InsightRow(
                        icon: Icons.error_outline,
                        label: strings.healthFailuresLabel,
                        value: healthFailuresStatus,
                        valueColor: stabilityNeedsAttention
                            ? _dangerSoft
                            : null,
                      ),
                      _InsightRow(
                        icon: Icons.battery_saver_outlined,
                        label: strings.backgroundModeLabel,
                        value: batteryOptimizationIgnored
                            ? strings.backgroundModeAllowed
                            : strings.backgroundModeRestricted,
                        valueColor: batteryOptimizationIgnored
                            ? null
                            : _dangerSoft,
                        onTap: batteryOptimizationIgnored
                            ? null
                            : onRequestBackgroundAccess,
                      ),
                      _InsightRow(
                        icon: Icons.event_available_outlined,
                        label: strings.subscriptionLabel,
                        value:
                            subscriptionStatus ?? strings.subscriptionUnknown,
                        valueColor: subscriptionNeedsAttention
                            ? _dangerSoft
                            : null,
                        trailing: subscriptionRefreshBusy
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : null,
                        onTap:
                            canRefreshSubscriptions && !subscriptionRefreshBusy
                            ? onRefreshSubscriptions
                            : null,
                      ),
                      if (countryFlag != null)
                        _InsightRow(
                          icon: Icons.flag_outlined,
                          label: strings.countryLabel,
                          value: countryFlag!,
                        ),
                      _InsightRow(
                        icon: Icons.speed_outlined,
                        label: strings.pingLabel,
                        value: pingLabel ?? 'ping',
                        onTap: onPing,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    strings.mobileNetworkAdvice,
                    style: const TextStyle(color: _mutedGold, height: 1.35),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    strings.androidVpnVisibleNote,
                    style: const TextStyle(
                      color: _mutedGold,
                      height: 1.35,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${strings.endpointLabel}: ${profile!.endpoint}',
                    style: const TextStyle(color: _mutedGold),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  bool _usesWarpDns(VpnProfile profile) {
    return profile.kind == VpnProfileKind.hysteria ||
        profile.kind == VpnProfileKind.hysteria2;
  }
}

class _InsightRow extends StatelessWidget {
  const _InsightRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final child = Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Icon(icon, color: _goldSoft, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _mutedGold, letterSpacing: 0),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: _goldSoft,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ).copyWith(color: valueColor),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 6),
            trailing!,
          ] else if (onTap != null) ...[
            const SizedBox(width: 6),
            const Icon(Icons.refresh, color: _mutedGold, size: 16),
          ],
        ],
      ),
    );

    if (onTap == null) {
      return child;
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(YurichRadii.control),
      child: child,
    );
  }
}

class _AppCenterPanel extends StatelessWidget {
  const _AppCenterPanel({
    required this.strings,
    required this.selectedTab,
    required this.onTabChanged,
    required this.language,
    required this.onLanguageChanged,
    required this.onSupport,
    required this.onTelegram,
    required this.onVk,
    required this.onDonate,
    required this.onDeveloper,
    required this.currentVersion,
    required this.externalUpdatesEnabled,
    required this.availableVersion,
    required this.updateMessage,
    required this.updateBusy,
    required this.updateProgress,
    required this.onCheck,
    required this.logs,
    required this.onExpansionChanged,
  });

  final _Strings strings;
  final _SupportTab selectedTab;
  final ValueChanged<_SupportTab> onTabChanged;
  final _AppLanguage language;
  final ValueChanged<_AppLanguage> onLanguageChanged;
  final VoidCallback onSupport;
  final VoidCallback onTelegram;
  final VoidCallback onVk;
  final VoidCallback onDonate;
  final VoidCallback onDeveloper;
  final String currentVersion;
  final bool externalUpdatesEnabled;
  final String? availableVersion;
  final String? updateMessage;
  final bool updateBusy;
  final double? updateProgress;
  final VoidCallback onCheck;
  final List<String> logs;
  final ValueChanged<bool> onExpansionChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: YurichGradients.centerPanel,
        borderRadius: BorderRadius.circular(YurichRadii.card),
        border: Border.all(color: YurichColors.border),
        boxShadow: [
          BoxShadow(
            color: _gold.withValues(alpha: 0.06),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SupportPanel(
              strings: strings,
              selectedTab: selectedTab,
              onTabChanged: onTabChanged,
              language: language,
              onLanguageChanged: onLanguageChanged,
              onSupport: onSupport,
              onTelegram: onTelegram,
              onVk: onVk,
              onDonate: onDonate,
              onDeveloper: onDeveloper,
            ),
            const _PanelDivider(),
            _UpdatePanel(
              strings: strings,
              currentVersion: currentVersion,
              externalUpdatesEnabled: externalUpdatesEnabled,
              availableVersion: availableVersion,
              message: updateMessage,
              busy: updateBusy,
              progress: updateProgress,
              onCheck: onCheck,
            ),
            const _PanelDivider(),
            _FaqPanel(strings: strings),
            const _PanelDivider(),
            _LogsPanel(
              strings: strings,
              logs: logs,
              onExpansionChanged: onExpansionChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class _PanelDivider extends StatelessWidget {
  const _PanelDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(height: 18, thickness: 1, color: YurichColors.border);
  }
}

class _SupportPanel extends StatelessWidget {
  const _SupportPanel({
    required this.strings,
    required this.selectedTab,
    required this.onTabChanged,
    required this.language,
    required this.onLanguageChanged,
    required this.onSupport,
    required this.onTelegram,
    required this.onVk,
    required this.onDonate,
    required this.onDeveloper,
  });

  final _Strings strings;
  final _SupportTab selectedTab;
  final ValueChanged<_SupportTab> onTabChanged;
  final _AppLanguage language;
  final ValueChanged<_AppLanguage> onLanguageChanged;
  final VoidCallback onSupport;
  final VoidCallback onTelegram;
  final VoidCallback onVk;
  final VoidCallback onDonate;
  final VoidCallback onDeveloper;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final actionWidth = constraints.maxWidth >= 340
            ? (constraints.maxWidth - 10) / 2
            : constraints.maxWidth;
        final actions = selectedTab == _SupportTab.help
            ? [
                _SupportAction(
                  icon: Icons.support_agent,
                  label: strings.support,
                  onPressed: onSupport,
                ),
                _SupportAction(
                  icon: Icons.mail_outline,
                  label: strings.developer,
                  onPressed: onDeveloper,
                ),
              ]
            : [
                _SupportAction(
                  icon: Icons.forum_outlined,
                  label: 'Telegram',
                  onPressed: onTelegram,
                ),
                _SupportAction(
                  icon: Icons.groups_outlined,
                  label: 'VK',
                  onPressed: onVk,
                ),
                _SupportAction(
                  icon: Icons.volunteer_activism_outlined,
                  label: strings.donate,
                  onPressed: onDonate,
                ),
              ];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.hub_outlined, color: _goldSoft, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    strings.contact,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<_SupportTab>(
                segments: [
                  ButtonSegment(
                    value: _SupportTab.help,
                    label: Text(strings.supportTabLabel(_SupportTab.help)),
                  ),
                  ButtonSegment(
                    value: _SupportTab.community,
                    label: Text(strings.supportTabLabel(_SupportTab.community)),
                  ),
                ],
                selected: {selectedTab},
                showSelectedIcon: false,
                onSelectionChanged: (value) {
                  final selected = value.isEmpty ? null : value.first;
                  if (selected != null) {
                    onTabChanged(selected);
                  }
                },
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  minimumSize: WidgetStateProperty.all(const Size(72, 40)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final action in actions)
                  SizedBox(
                    width: actionWidth,
                    height: 50,
                    child: _SupportActionButton(action: action),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: _surfaceMetric,
                borderRadius: BorderRadius.circular(YurichRadii.control),
                border: Border.all(color: _gold.withValues(alpha: 0.16)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.translate, color: _mutedGold, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      strings.language,
                      style: const TextStyle(color: _mutedGold),
                    ),
                  ),
                  SegmentedButton<_AppLanguage>(
                    segments: const [
                      ButtonSegment(value: _AppLanguage.ru, label: Text('RU')),
                      ButtonSegment(value: _AppLanguage.en, label: Text('EN')),
                    ],
                    selected: {language},
                    showSelectedIcon: false,
                    onSelectionChanged: (value) {
                      final selected = value.isEmpty ? null : value.first;
                      if (selected != null) {
                        onLanguageChanged(selected);
                      }
                    },
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      minimumSize: WidgetStateProperty.all(const Size(52, 34)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SupportAction {
  const _SupportAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
}

class _SupportActionButton extends StatelessWidget {
  const _SupportActionButton({required this.action});

  final _SupportAction action;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: action.onPressed,
      style: OutlinedButton.styleFrom(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        side: BorderSide(color: _gold.withValues(alpha: 0.28)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YurichRadii.control),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(action.icon, size: 20),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              action.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _UpdatePanel extends StatelessWidget {
  const _UpdatePanel({
    required this.strings,
    required this.currentVersion,
    required this.externalUpdatesEnabled,
    required this.availableVersion,
    required this.message,
    required this.busy,
    required this.progress,
    required this.onCheck,
  });

  final _Strings strings;
  final String currentVersion;
  final bool externalUpdatesEnabled;
  final String? availableVersion;
  final String? message;
  final bool busy;
  final double? progress;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final hasUpdate = availableVersion != null;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      leading: Icon(
        hasUpdate ? Icons.new_releases_outlined : Icons.system_update_alt,
        color: hasUpdate ? _gold : _goldSoft,
      ),
      title: Text(strings.updates),
      subtitle: Text(
        hasUpdate
            ? strings.updateAvailable(availableVersion!)
            : message ?? strings.updateIdle(currentVersion),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: hasUpdate ? _goldSoft : _mutedGold),
      ),
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(YurichRadii.panel),
            border: Border.all(color: _gold.withValues(alpha: 0.18)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hasUpdate) ...[
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(YurichRadii.control),
                      border: Border.all(color: _gold.withValues(alpha: 0.32)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.notifications_active_outlined,
                            color: _goldSoft,
                            size: 22,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              strings.updateAvailableBody(availableVersion!),
                              style: const TextStyle(
                                color: _goldSoft,
                                height: 1.3,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Text(
                  externalUpdatesEnabled
                      ? strings.updateDescription
                      : strings.playUpdateDescription,
                  style: const TextStyle(color: _mutedGold, height: 1.35),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(
                      Icons.verified_outlined,
                      color: _goldSoft,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        externalUpdatesEnabled
                            ? strings.updateChannel
                            : strings.playUpdateChannel,
                        style: const TextStyle(color: _goldSoft, height: 1.25),
                      ),
                    ),
                  ],
                ),
                if (busy) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: progress),
                ],
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: busy ? null : onCheck,
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_for_offline_outlined),
                  label: Text(
                    externalUpdatesEnabled
                        ? strings.checkUpdates
                        : strings.openGooglePlay,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _FaqPanel extends StatelessWidget {
  const _FaqPanel({required this.strings});

  final _Strings strings;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      leading: const Icon(Icons.help_outline, color: _goldSoft),
      title: Text(strings.faq),
      children: [
        for (final item in strings.faqItems)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _surface,
                borderRadius: BorderRadius.circular(YurichRadii.panel),
                border: Border.all(color: YurichColors.border),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.question,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item.answer,
                      style: const TextStyle(color: _mutedGold, height: 1.35),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _LogsPanel extends StatelessWidget {
  const _LogsPanel({
    required this.strings,
    required this.logs,
    required this.onExpansionChanged,
  });

  final _Strings strings;
  final List<String> logs;
  final ValueChanged<bool> onExpansionChanged;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      onExpansionChanged: onExpansionChanged,
      tilePadding: EdgeInsets.zero,
      title: Text(strings.logs),
      children: [
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 92),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _ink,
            borderRadius: BorderRadius.circular(YurichRadii.panel),
            border: Border.all(color: _gold.withValues(alpha: 0.18)),
          ),
          child: Text(
            logs.isEmpty ? strings.noLogs : logs.join('\n'),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

class _FaqItem {
  const _FaqItem({required this.question, required this.answer});

  final String question;
  final String answer;
}
