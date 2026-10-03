import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/connection_status.dart';
import '../models/connection_ui_state.dart';
import '../theme/yurich_theme.dart';

enum TvProtocolGroup { all, vless, hysteria, naive, xhttp }

class TvProfileItem {
  const TvProfileItem({
    required this.id,
    required this.name,
    required this.protocol,
    required this.country,
    required this.latency,
    required this.group,
    this.selected = false,
    this.active = false,
  });

  final String id;
  final String name;
  final String protocol;
  final String country;
  final String latency;
  final TvProtocolGroup group;
  final bool selected;
  final bool active;
}

enum _TvSection { profiles, settings, logs }

class TvHomeScreen extends StatefulWidget {
  const TvHomeScreen({
    super.key,
    required this.russian,
    required this.connection,
    required this.connected,
    required this.busy,
    required this.message,
    required this.uptime,
    required this.version,
    required this.smartRoute,
    required this.autoDns,
    required this.refreshing,
    required this.profiles,
    required this.logs,
    required this.onToggle,
    required this.onSelect,
    required this.onImport,
    required this.onRefresh,
    required this.onSmartRoute,
    required this.onAutoDns,
    required this.onLogsVisible,
    required this.onLanguage,
    required this.onReleases,
    required this.onPrivacy,
  });

  final bool russian;
  final ConnectionUiState connection;
  final bool connected;
  final bool busy;
  final String message;
  final String uptime;
  final String version;
  final bool smartRoute;
  final bool autoDns;
  final bool refreshing;
  final List<TvProfileItem> profiles;
  final List<String> logs;
  final VoidCallback onToggle;
  final ValueChanged<String> onSelect;
  final VoidCallback onImport;
  final VoidCallback onRefresh;
  final ValueChanged<bool> onSmartRoute;
  final ValueChanged<bool> onAutoDns;
  final ValueChanged<bool> onLogsVisible;
  final VoidCallback onLanguage;
  final VoidCallback onReleases;
  final VoidCallback onPrivacy;

  @override
  State<TvHomeScreen> createState() => _TvHomeScreenState();
}

class _TvHomeScreenState extends State<TvHomeScreen> {
  var _section = _TvSection.profiles;
  var _group = TvProtocolGroup.all;
  final _profilesTabFocus = FocusNode(debugLabel: 'tv-profiles-tab');

  String t(String ru, String en) => widget.russian ? ru : en;

  @override
  void dispose() {
    _profilesTabFocus.dispose();
    super.dispose();
  }

  void _showSection(_TvSection section) {
    if (_section == section) return;
    setState(() => _section = section);
    widget.onLogsVisible(section == _TvSection.logs);
  }

  String get _statusLabel => widget.russian
      ? widget.connection.status.displayName
      : switch (widget.connection.status) {
          ConnectionStatus.connected => 'Connected',
          ConnectionStatus.idle => 'Idle',
          ConnectionStatus.networkChanging => 'Network changed',
          ConnectionStatus.degraded => 'Unstable connection',
          ConnectionStatus.reconnecting => 'Reconnecting',
          ConnectionStatus.failed => 'Connection failed',
          ConnectionStatus.disconnected => 'Disconnected',
          ConnectionStatus.connecting => 'Connecting',
        };

  Color get _statusColor => switch (widget.connection.status) {
    ConnectionStatus.connected || ConnectionStatus.idle => YurichColors.success,
    ConnectionStatus.failed => YurichColors.danger,
    ConnectionStatus.degraded ||
    ConnectionStatus.reconnecting ||
    ConnectionStatus.networkChanging => YurichColors.warning,
    _ => YurichColors.textSecondary,
  };

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _section == _TvSection.profiles,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _showSection(_TvSection.profiles);
          _profilesTabFocus.requestFocus();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0C1219),
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: constraints.maxWidth * 0.05,
                  vertical: constraints.maxHeight * 0.05,
                ),
                child: FocusTraversalGroup(
                  policy: ReadingOrderTraversalPolicy(),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Image(
                            image: AssetImage('assets/images/app_icon.png'),
                            width: 48,
                            height: 48,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Yurich Connect TV',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          TvAction(
                            key: const ValueKey('tv-import'),
                            autofocus: widget.profiles.isEmpty,
                            tooltip: t('Добавить подписку', 'Add subscription'),
                            onPressed: widget.busy ? null : widget.onImport,
                            child: const Icon(Icons.add_link),
                          ),
                          const SizedBox(width: 8),
                          TvAction(
                            key: const ValueKey('tv-refresh'),
                            tooltip: t(
                              'Обновить подписки',
                              'Refresh subscriptions',
                            ),
                            onPressed:
                                widget.busy ||
                                    widget.refreshing ||
                                    widget.profiles.isEmpty
                                ? null
                                : widget.onRefresh,
                            child: Icon(
                              widget.refreshing
                                  ? Icons.hourglass_top
                                  : Icons.refresh,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Divider(height: 1, color: Color(0xFF303942)),
                      const SizedBox(height: 16),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(flex: 4, child: _connectionPane()),
                            const VerticalDivider(
                              width: 40,
                              color: Color(0xFF303942),
                            ),
                            Expanded(
                              flex: 7,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TvAction(
                                          key: const ValueKey(
                                            'tv-profiles-tab',
                                          ),
                                          focusNode: _profilesTabFocus,
                                          selected:
                                              _section == _TvSection.profiles,
                                          onPressed: () =>
                                              _showSection(_TvSection.profiles),
                                          child: Text(t('Профили', 'Profiles')),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      TvAction(
                                        key: const ValueKey('tv-settings-tab'),
                                        selected:
                                            _section == _TvSection.settings,
                                        tooltip: t('Настройки', 'Settings'),
                                        onPressed: () =>
                                            _showSection(_TvSection.settings),
                                        child: const Icon(
                                          Icons.settings_outlined,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      TvAction(
                                        key: const ValueKey('tv-logs-tab'),
                                        selected: _section == _TvSection.logs,
                                        tooltip: t('Логи', 'Logs'),
                                        onPressed: () =>
                                            _showSection(_TvSection.logs),
                                        child: const Icon(
                                          Icons.article_outlined,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Expanded(
                                    child: switch (_section) {
                                      _TvSection.profiles => _profilesPane(),
                                      _TvSection.settings => _settingsPane(),
                                      _TvSection.logs => TvScrollableText(
                                        key: const ValueKey('tv-log-content'),
                                        text: widget.logs.isEmpty
                                            ? t('Логов пока нет', 'No logs yet')
                                            : widget.logs.join('\n\n'),
                                      ),
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _connectionPane() {
    final connection = widget.connection;
    final selected = widget.profiles
        .where((profile) => profile.selected)
        .firstOrNull;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(
            widget.connected
                ? Icons.verified_user_outlined
                : Icons.shield_outlined,
            size: 40,
            color: _statusColor,
          ),
          const SizedBox(height: 12),
          Text(
            _statusLabel,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: _statusColor,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            connection.profileName ??
                selected?.name ??
                t('Профиль не выбран', 'No profile selected'),
            key: const ValueKey('tv-selected-name'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 18),
          ),
          const SizedBox(height: 6),
          Text(
            connection.protocolDisplayName ?? selected?.protocol ?? '',
            style: const TextStyle(
              fontSize: 16,
              color: YurichColors.textSecondary,
            ),
          ),
          const SizedBox(height: 18),
          TvAction(
            key: const ValueKey('tv-connect'),
            autofocus: widget.profiles.isNotEmpty,
            primary: true,
            onPressed: widget.busy || widget.profiles.isEmpty
                ? null
                : widget.onToggle,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  widget.busy ? Icons.hourglass_top : Icons.power_settings_new,
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    widget.busy
                        ? t('Подождите', 'Please wait')
                        : widget.connected
                        ? t('Отключить', 'Disconnect')
                        : t('Подключить', 'Connect'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _metric(
            Icons.arrow_upward,
            t('Отправка', 'Upload'),
            connection.uploadSpeed,
          ),
          _metric(
            Icons.arrow_downward,
            t('Загрузка', 'Download'),
            connection.downloadSpeed,
          ),
          _metric(Icons.schedule, t('Время', 'Uptime'), widget.uptime),
          _metric(
            Icons.data_usage,
            t('Трафик', 'Traffic'),
            connection.totalTraffic,
          ),
          const SizedBox(height: 14),
          Text(
            widget.message,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: YurichColors.textSecondary,
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }

  Widget _metric(IconData icon, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Icon(icon, size: 20, color: YurichColors.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: YurichColors.textSecondary),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    ),
  );

  Widget _profilesPane() {
    final profiles = widget.profiles
        .where(
          (profile) => _group == TvProtocolGroup.all || profile.group == _group,
        )
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<TvProtocolGroup>(
            segments: [
              ButtonSegment(
                value: TvProtocolGroup.all,
                label: Text(t('Все', 'All')),
              ),
              const ButtonSegment(
                value: TvProtocolGroup.vless,
                label: Text('VLESS'),
              ),
              const ButtonSegment(
                value: TvProtocolGroup.hysteria,
                label: Text('Hysteria'),
              ),
              const ButtonSegment(
                value: TvProtocolGroup.naive,
                label: Text('NaiveProxy'),
              ),
              const ButtonSegment(
                value: TvProtocolGroup.xhttp,
                label: Text('XHTTP'),
              ),
            ],
            selected: {_group},
            onSelectionChanged: (selection) =>
                setState(() => _group = selection.single),
            showSelectedIcon: false,
            style: ButtonStyle(
              minimumSize: const WidgetStatePropertyAll(Size(64, 48)),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              side: WidgetStateProperty.resolveWith(
                (states) => BorderSide(
                  color: states.contains(WidgetState.focused)
                      ? YurichColors.warning
                      : const Color(0xFF526171),
                  width: 2,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: profiles.isEmpty
              ? Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    t('Нет профилей', 'No profiles'),
                    style: const TextStyle(
                      fontSize: 18,
                      color: YurichColors.textSecondary,
                    ),
                  ),
                )
              : TvProfileList(
                  profiles: profiles,
                  enabled: !widget.busy,
                  onSelect: widget.onSelect,
                ),
        ),
      ],
    );
  }

  Widget _settingsPane() => ListView(
    children: [
      _setting(
        key: 'tv-smart-route',
        title: 'Smart Route',
        icon: Icons.alt_route,
        value: widget.smartRoute,
        onChanged: widget.onSmartRoute,
      ),
      const SizedBox(height: 10),
      _setting(
        key: 'tv-auto-dns',
        title: 'Auto DNS',
        icon: Icons.dns_outlined,
        value: widget.autoDns,
        onChanged: widget.onAutoDns,
      ),
      const SizedBox(height: 10),
      TvAction(
        key: const ValueKey('tv-language'),
        onPressed: widget.onLanguage,
        child: _command(
          Icons.language,
          t('Язык: Русский', 'Language: English'),
        ),
      ),
      const SizedBox(height: 10),
      TvAction(
        onPressed: widget.onReleases,
        child: _command(
          Icons.open_in_new,
          t('Релизы TV на GitHub', 'TV releases on GitHub'),
        ),
      ),
      const SizedBox(height: 10),
      TvAction(
        onPressed: widget.onPrivacy,
        child: _command(
          Icons.policy_outlined,
          t('Конфиденциальность', 'Privacy policy'),
        ),
      ),
      const SizedBox(height: 16),
      Text(
        'Yurich Connect TV ${widget.version}\nivan-it.net · hello@ivan-it.net',
        style: const TextStyle(color: YurichColors.textSecondary, fontSize: 16),
      ),
    ],
  );

  Widget _setting({
    required String key,
    required String title,
    required IconData icon,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => TvAction(
    key: ValueKey(key),
    onPressed: widget.busy ? null : () => onChanged(!value),
    child: Row(
      children: [
        Icon(icon),
        const SizedBox(width: 12),
        Expanded(child: Text(title)),
        ExcludeFocus(
          child: Switch(
            value: value,
            onChanged: widget.busy ? null : onChanged,
          ),
        ),
      ],
    ),
  );

  Widget _command(IconData icon, String text) => Row(
    children: [
      Icon(icon),
      const SizedBox(width: 12),
      Expanded(child: Text(text)),
    ],
  );
}

class TvAction extends StatelessWidget {
  const TvAction({
    super.key,
    required this.onPressed,
    required this.child,
    this.tooltip,
    this.focusNode,
    this.autofocus = false,
    this.selected = false,
    this.primary = false,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final String? tooltip;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool selected;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final button = OutlinedButton(
      focusNode: focusNode,
      autofocus: autofocus,
      onPressed: onPressed,
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(52, 52)),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontFamily: 'Roboto',
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
          ),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        side: WidgetStateProperty.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.focused)
                ? YurichColors.warning
                : selected
                ? YurichColors.accentCyan
                : const Color(0xFF3D4956),
            width: 2,
          ),
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? const Color(0xFF65717D)
              : primary
              ? const Color(0xFF071218)
              : YurichColors.textPrimary,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? const Color(0xFF19212A)
              : primary
              ? YurichColors.accentCyan
              : states.contains(WidgetState.focused)
              ? const Color(0xFF33404E)
              : selected
              ? const Color(0xFF243039)
              : const Color(0xFF182029),
        ),
        animationDuration: const Duration(milliseconds: 100),
      ),
      child: child,
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

class TvProfileList extends StatefulWidget {
  const TvProfileList({
    super.key,
    required this.profiles,
    required this.enabled,
    required this.onSelect,
  });

  final List<TvProfileItem> profiles;
  final bool enabled;
  final ValueChanged<String> onSelect;

  @override
  State<TvProfileList> createState() => _TvProfileListState();
}

class _TvProfileListState extends State<TvProfileList> {
  double get _extent =>
      86 * math.max(1.0, MediaQuery.textScalerOf(context).scale(18) / 18);
  final _scroll = ScrollController();
  final _focusNodes = <String, FocusNode>{};

  FocusNode _node(String id) => _focusNodes.putIfAbsent(
    id,
    () => FocusNode(debugLabel: 'tv-profile-$id'),
  );

  @override
  void didUpdateWidget(covariant TvProfileList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ids = widget.profiles.map((profile) => profile.id).toSet();
    for (final id
        in _focusNodes.keys.where((id) => !ids.contains(id)).toList()) {
      _focusNodes.remove(id)?.dispose();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _focusIndex(int index) {
    if (!_scroll.hasClients || index < 0 || index >= widget.profiles.length) {
      return;
    }
    final id = widget.profiles[index].id;
    // Materialize the destination in the lazy list before requesting focus.
    final target =
        index * _extent -
        math.max(0, (_scroll.position.viewportDimension - _extent) / 2);
    _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          widget.enabled &&
          widget.profiles.any((profile) => profile.id == id)) {
        _node(id).requestFocus();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) => Scrollbar(
    controller: _scroll,
    thumbVisibility: true,
    child: ListView.builder(
      key: const ValueKey('tv-profile-list'),
      controller: _scroll,
      itemExtent: _extent,
      itemCount: widget.profiles.length,
      itemBuilder: (context, index) {
        final profile = widget.profiles[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 8, right: 12),
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: (node, event) {
              if (!widget.enabled ||
                  (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
                return KeyEventResult.ignored;
              }
              final next = event.logicalKey == LogicalKeyboardKey.arrowDown
                  ? index + 1
                  : event.logicalKey == LogicalKeyboardKey.arrowUp
                  ? index - 1
                  : -1;
              if (next >= 0 && next < widget.profiles.length) {
                _focusIndex(next);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: TvAction(
              key: ValueKey('tv-profile-${profile.id}'),
              focusNode: _node(profile.id),
              selected: profile.selected,
              onPressed: widget.enabled
                  ? () => widget.onSelect(profile.id)
                  : null,
              child: Row(
                children: [
                  Icon(
                    profile.active
                        ? Icons.check_circle
                        : profile.selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: profile.active ? YurichColors.success : null,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          profile.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${profile.country}  ${profile.protocol}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            color: YurichColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 76,
                    child: Text(
                      profile.latency,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

class TvScrollableText extends StatefulWidget {
  const TvScrollableText({super.key, required this.text});

  final String text;

  @override
  State<TvScrollableText> createState() => _TvScrollableTextState();
}

class _TvScrollableTextState extends State<TvScrollableText> {
  final _scroll = ScrollController();
  final _focus = FocusNode(debugLabel: 'tv-log-scroll');
  var _focused = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    onFocusChange: (value) => setState(() => _focused = value),
    onKeyEvent: (node, event) {
      if (!_scroll.hasClients ||
          (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
        return KeyEventResult.ignored;
      }
      final delta = switch (event.logicalKey) {
        LogicalKeyboardKey.arrowDown => 64.0,
        LogicalKeyboardKey.arrowUp => -64.0,
        LogicalKeyboardKey.pageDown => _scroll.position.viewportDimension,
        LogicalKeyboardKey.pageUp => -_scroll.position.viewportDimension,
        _ => 0.0,
      };
      final next = (_scroll.offset + delta).clamp(
        0,
        _scroll.position.maxScrollExtent,
      );
      if (delta == 0 || next == _scroll.offset) return KeyEventResult.ignored;
      _scroll.jumpTo(next.toDouble());
      return KeyEventResult.handled;
    },
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(
          color: _focused ? YurichColors.warning : const Color(0xFF3D4956),
          width: 2,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Scrollbar(
        controller: _scroll,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.all(16),
          child: Text(
            widget.text,
            style: const TextStyle(fontSize: 16, height: 1.5),
          ),
        ),
      ),
    ),
  );
}

Future<String?> showTvImportDialog(
  BuildContext context, {
  required bool russian,
}) => showDialog<String>(
  context: context,
  builder: (_) => _TvImportDialog(russian: russian),
);

class _TvImportDialog extends StatefulWidget {
  const _TvImportDialog({required this.russian});

  final bool russian;

  @override
  State<_TvImportDialog> createState() => _TvImportDialogState();
}

class _TvImportDialogState extends State<_TvImportDialog> {
  final _text = TextEditingController();
  var _clipboardBusy = false;
  String t(String ru, String en) => widget.russian ? ru : en;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    if (_clipboardBusy) return;
    setState(() => _clipboardBusy = true);
    try {
      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      if (mounted) {
        _text.text = (clipboard?.text ?? '').characters.take(16384).toString();
      }
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t('Буфер обмена недоступен', 'Clipboard unavailable'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _clipboardBusy = false);
    }
  }

  void _submit() {
    final value = _text.text.trim();
    if (value.isNotEmpty) Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) => Dialog(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 680),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: FocusTraversalGroup(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t('Добавить подписку', 'Add subscription'),
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  TvAction(
                    tooltip: t('Закрыть', 'Close'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              TextField(
                key: const ValueKey('tv-import-input'),
                controller: _text,
                autofocus: true,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                enableSuggestions: false,
                autocorrect: false,
                smartDashesType: SmartDashesType.disabled,
                smartQuotesType: SmartQuotesType.disabled,
                maxLength: 16384,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: t(
                    'Ссылка подписки или профиля',
                    'Subscription or profile link',
                  ),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  TvAction(
                    key: const ValueKey('tv-import-submit'),
                    primary: true,
                    onPressed: _text.text.trim().isEmpty ? null : _submit,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.add_link),
                        const SizedBox(width: 8),
                        Text(t('Импортировать', 'Import')),
                      ],
                    ),
                  ),
                  TvAction(
                    key: const ValueKey('tv-import-paste'),
                    onPressed: _clipboardBusy ? null : _paste,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.content_paste),
                        const SizedBox(width: 8),
                        Text(t('Вставить', 'Paste')),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class TvLauncherBanner extends StatelessWidget {
  const TvLauncherBanner({super.key});

  @override
  Widget build(BuildContext context) => const Material(
    color: Color(0xFF0C1219),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image(
            image: AssetImage('assets/images/app_icon.png'),
            width: 80,
            height: 80,
          ),
          SizedBox(height: 4),
          Text(
            'Yurich Connect',
            style: TextStyle(
              fontFamily: 'Roboto',
              fontSize: 24,
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            'TV',
            style: TextStyle(
              fontFamily: 'Roboto',
              fontSize: 18,
              color: YurichColors.accentCyan,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    ),
  );
}
