part of 'home_screen.dart';

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
    required this.distributionChannel,
    required this.availableVersion,
    required this.updateMessage,
    required this.updateBusy,
    required this.updateProgress,
    required this.onCheck,
    required this.logs,
    required this.logsExpanded,
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
  final AppDistributionChannel distributionChannel;
  final String? availableVersion;
  final String? updateMessage;
  final bool updateBusy;
  final double? updateProgress;
  final VoidCallback onCheck;
  final List<String> logs;
  final bool logsExpanded;
  final ValueChanged<bool> onExpansionChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: _UpdatePanel(
              strings: strings,
              currentVersion: currentVersion,
              distributionChannel: distributionChannel,
              availableVersion: availableVersion,
              message: updateMessage,
              busy: updateBusy,
              progress: updateProgress,
              onCheck: onCheck,
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const _AppSettingIcon(Icons.translate_rounded),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          strings.language,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<_AppLanguage>(
                    key: const ValueKey('mobile-app-language'),
                    segments: const [
                      ButtonSegment(value: _AppLanguage.ru, label: Text('RU')),
                      ButtonSegment(value: _AppLanguage.en, label: Text('EN')),
                    ],
                    selected: {language},
                    showSelectedIcon: false,
                    onSelectionChanged: (value) {
                      if (value.isNotEmpty) onLanguageChanged(value.first);
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          _SupportPanel(
            strings: strings,
            selectedTab: selectedTab,
            onTabChanged: onTabChanged,
            onSupport: onSupport,
            onTelegram: onTelegram,
            onVk: onVk,
            onDonate: onDonate,
            onDeveloper: onDeveloper,
          ),
          const SizedBox(height: 10),
          Card(child: _FaqPanel(strings: strings)),
          const SizedBox(height: 10),
          Card(
            child: _LogsPanel(
              strings: strings,
              logs: logs,
              expanded: logsExpanded,
              onExpansionChanged: onExpansionChanged,
              russian: language == _AppLanguage.ru,
            ),
          ),
        ],
      ),
    );
  }
}

class _AppSettingIcon extends StatelessWidget {
  const _AppSettingIcon(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: YurichMobileColors.blueTint,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SizedBox.square(
        dimension: 36,
        child: Icon(icon, color: YurichMobileColors.blue, size: 20),
      ),
    );
  }
}

class _SupportPanel extends StatelessWidget {
  const _SupportPanel({
    required this.strings,
    required this.selectedTab,
    required this.onTabChanged,
    required this.onSupport,
    required this.onTelegram,
    required this.onVk,
    required this.onDonate,
    required this.onDeveloper,
  });

  final _Strings strings;
  final _SupportTab selectedTab;
  final ValueChanged<_SupportTab> onTabChanged;
  final VoidCallback onSupport;
  final VoidCallback onTelegram;
  final VoidCallback onVk;
  final VoidCallback onDonate;
  final VoidCallback onDeveloper;

  @override
  Widget build(BuildContext context) {
    final actions = selectedTab == _SupportTab.help
        ? [
            _SupportAction(
              icon: Icons.support_agent_rounded,
              label: strings.support,
              onPressed: onSupport,
            ),
            _SupportAction(
              icon: Icons.mail_outline_rounded,
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

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const _AppSettingIcon(Icons.support_agent_rounded),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    strings.contact,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SegmentedButton<_SupportTab>(
              key: const ValueKey('mobile-app-support-tab'),
              segments: [
                for (final tab in _SupportTab.values)
                  ButtonSegment(
                    value: tab,
                    label: Text(
                      strings.supportTabLabel(tab),
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
              selected: {selectedTab},
              showSelectedIcon: false,
              onSelectionChanged: (value) {
                if (value.isNotEmpty) onTabChanged(value.first);
              },
            ),
            const SizedBox(height: 4),
            for (final action in actions) _SupportActionButton(action: action),
          ],
        ),
      ),
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
    return TextButton(
      onPressed: action.onPressed,
      style: TextButton.styleFrom(
        alignment: AlignmentDirectional.centerStart,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Row(
        children: [
          Icon(action.icon, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              action.label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.open_in_new_rounded, size: 16),
        ],
      ),
    );
  }
}

class _UpdatePanel extends StatelessWidget {
  const _UpdatePanel({
    required this.strings,
    required this.currentVersion,
    required this.distributionChannel,
    required this.availableVersion,
    required this.message,
    required this.busy,
    required this.progress,
    required this.onCheck,
  });

  final _Strings strings;
  final String currentVersion;
  final AppDistributionChannel distributionChannel;
  final String? availableVersion;
  final String? message;
  final bool busy;
  final double? progress;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final hasUpdate = availableVersion != null;
    final description = switch (distributionChannel) {
      AppDistributionChannel.github => strings.updateDescription,
      AppDistributionChannel.tv => 'Yurich Connect TV APK / GitHub',
      AppDistributionChannel.play => strings.playUpdateDescription,
      AppDistributionChannel.soak => strings.soakUpdateDescription,
      AppDistributionChannel.unknown => strings.unknownUpdateDescription,
    };
    final channelLabel = switch (distributionChannel) {
      AppDistributionChannel.github =>
        AppUpdateService.usesTestingChannel(currentVersion)
            ? strings.testingUpdateChannel
            : strings.updateChannel,
      AppDistributionChannel.tv => 'GitHub / Android TV',
      AppDistributionChannel.play => strings.playUpdateChannel,
      AppDistributionChannel.soak => strings.soakUpdateChannel,
      AppDistributionChannel.unknown => strings.unknownUpdateChannel,
    };
    final actionLabel = switch (distributionChannel) {
      AppDistributionChannel.github => strings.checkUpdates,
      AppDistributionChannel.tv => 'GitHub',
      AppDistributionChannel.play => strings.openGooglePlay,
      AppDistributionChannel.soak => strings.updatesDisabled,
      AppDistributionChannel.unknown => strings.retry,
    };
    final actionIcon = switch (distributionChannel) {
      AppDistributionChannel.github => Icons.download_for_offline_outlined,
      AppDistributionChannel.tv => Icons.open_in_new,
      AppDistributionChannel.play => Icons.open_in_new,
      AppDistributionChannel.soak => Icons.science_outlined,
      AppDistributionChannel.unknown => Icons.refresh,
    };
    final actionEnabled = distributionChannel != AppDistributionChannel.soak;
    return ExpansionTile(
      key: const PageStorageKey('mobile-app-updates'),
      leading: _AppSettingIcon(
        hasUpdate ? Icons.new_releases_outlined : Icons.system_update_outlined,
      ),
      title: Text(strings.updates),
      subtitle: Text(
        hasUpdate
            ? strings.updateAvailable(availableVersion!)
            : message ?? strings.updateIdle(currentVersion),
      ),
      minTileHeight: 64,
      shape: const Border(),
      collapsedShape: const Border(),
      childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasUpdate) ...[
          DecoratedBox(
            decoration: BoxDecoration(
              color: YurichMobileColors.blueTint,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                strings.updateAvailableBody(availableVersion!),
                style: const TextStyle(
                  color: YurichMobileColors.blue,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (message != null) ...[Text(message!), const SizedBox(height: 8)],
        ],
        Text(
          description,
          style: const TextStyle(color: YurichMobileColors.secondary),
        ),
        const SizedBox(height: 8),
        Text(
          channelLabel,
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(color: YurichMobileColors.blue),
        ),
        if (busy) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(value: progress),
        ],
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: busy || !actionEnabled ? null : onCheck,
          icon: Icon(actionIcon),
          label: Text(actionLabel, textAlign: TextAlign.center),
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
      key: const PageStorageKey('mobile-app-faq'),
      leading: const _AppSettingIcon(Icons.help_outline_rounded),
      title: Text(strings.faq),
      minTileHeight: 64,
      shape: const Border(),
      collapsedShape: const Border(),
      childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, item) in strings.faqItems.indexed) ...[
          if (index > 0) const Divider(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
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
                  style: const TextStyle(
                    color: YurichMobileColors.secondary,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _LogsPanel extends StatelessWidget {
  const _LogsPanel({
    required this.strings,
    required this.logs,
    required this.expanded,
    required this.onExpansionChanged,
    required this.russian,
  });

  final _Strings strings;
  final List<String> logs;
  final bool expanded;
  final ValueChanged<bool> onExpansionChanged;
  final bool russian;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          expanded: expanded,
          child: ListTile(
            key: const ValueKey('mobile-app-logs'),
            leading: const _AppSettingIcon(Icons.receipt_long_outlined),
            title: Text(strings.logs),
            minTileHeight: 64,
            trailing: Icon(expanded ? Icons.expand_less : Icons.expand_more),
            onTap: () => onExpansionChanged(!expanded),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!kIsWeb &&
                    defaultTargetPlatform == TargetPlatform.android) ...[
                  DiagnosticsPanel(russian: russian),
                  const SizedBox(height: 12),
                ],
                Container(
                  constraints: const BoxConstraints(minHeight: 80),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: YurichMobileColors.canvas,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: YurichMobileColors.line),
                  ),
                  child: Text(
                    logs.isEmpty ? strings.noLogs : logs.join('\n'),
                    style: const TextStyle(
                      color: YurichMobileColors.ink,
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
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
