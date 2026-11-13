import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/smart_route_apps_service.dart';
import '../theme/yurich_theme.dart';

final class SmartRouteAppsDialog extends StatefulWidget {
  const SmartRouteAppsDialog({
    super.key,
    required this.snapshot,
    required this.builtInPackages,
    required this.smartRouteEnabled,
    required this.managedProfile,
    required this.vpnActive,
    required this.russian,
  });

  final SmartRouteAppsSnapshot snapshot;
  final Set<String> builtInPackages;
  final bool smartRouteEnabled;
  final bool managedProfile;
  final bool vpnActive;
  final bool russian;

  @override
  State<SmartRouteAppsDialog> createState() => _SmartRouteAppsDialogState();
}

class _SmartRouteAppsDialogState extends State<SmartRouteAppsDialog> {
  late final Set<String> _catalogIds = widget.snapshot.candidates
      .map((app) => app.packageId)
      .toSet();
  late final Set<String> _choiceIds = _catalogIds.difference(
    widget.builtInPackages,
  );
  late final Set<String> _legacyBuiltIns = widget.builtInPackages.difference(
    _catalogIds,
  );
  late final Set<String> _initial = widget.snapshot.selected.intersection(
    _choiceIds,
  );
  late final Set<String> _draft = {..._initial};

  String _t(String ru, String en) => widget.russian ? ru : en;

  String _status(SmartRouteAppRoute route) => switch (route) {
    SmartRouteAppRoute.applied => _t(
      'Напрямую · применено',
      'Direct · applied',
    ),
    SmartRouteAppRoute.protected => _t(
      'Приостановлено защитой',
      'Suspended by protection',
    ),
    SmartRouteAppRoute.missing => _t(
      'Не установлено · не применяется',
      'Not installed · not applied',
    ),
    SmartRouteAppRoute.unavailable => _t(
      'Недоступно на этом устройстве',
      'Unavailable on this device',
    ),
    SmartRouteAppRoute.unselected => _t('Не выбрано', 'Not selected'),
    SmartRouteAppRoute.smartRouteOff => _t(
      'Smart Route выключен',
      'Smart Route is off',
    ),
    SmartRouteAppRoute.rawProfile => _t(
      'Пользовательский конфиг не изменяется',
      'Custom config is unchanged',
    ),
    SmartRouteAppRoute.otherAppMode => _t(
      'Активен другой режим приложений',
      'Another per-app mode is active',
    ),
    SmartRouteAppRoute.nextConnection => _t(
      'При следующем подключении',
      'On the next connection',
    ),
    SmartRouteAppRoute.unconfirmed => _t(
      'Маршрут не подтверждён',
      'Route not confirmed',
    ),
    SmartRouteAppRoute.notApplied => _t(
      'Не применено в текущем VPN',
      'Not applied to the current VPN',
    ),
  };

  @override
  Widget build(BuildContext context) => Theme(
    data: YurichTheme.mobile,
    child: Builder(builder: _buildDialog),
  );

  Widget _buildDialog(BuildContext context) {
    bool onDevice(SmartRouteAppCandidate app) => switch (app.availability) {
      SmartRouteAppAvailability.installed ||
      SmartRouteAppAvailability.disabled ||
      SmartRouteAppAvailability.sharedUid => true,
      _ => false,
    };
    final catalog = widget.snapshot.candidates;
    final installed = catalog.where(onDevice).toList(growable: false);
    final remaining = catalog
        .where((app) => !onDevice(app))
        .toList(growable: false);
    final chosen = _draft.length + _catalogIds.length - _choiceIds.length;
    final changed = !setEquals(_draft, _initial);
    final mayReconnect =
        widget.vpnActive &&
        widget.smartRouteEnabled &&
        widget.managedProfile &&
        widget.snapshot.supported &&
        widget.snapshot.protectionKnown &&
        !widget.snapshot.legacyAppMode &&
        !widget.snapshot.protected;
    return AlertDialog(
      backgroundColor: YurichMobileColors.canvas,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      title: Text(_t('Приложения напрямую', 'Apps that bypass VPN')),
      scrollable: true,
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _t(
                'При включённом Smart Route весь трафик выбранных доступных приложений идёт вне VPN. Сервисы видят обычный IP сети. Kill Switch и блокировка Android имеют приоритет.',
                'With Smart Route on, all traffic from selected eligible apps bypasses VPN. Services see your regular network IP. Kill Switch and Android lockdown take precedence.',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _t(
                'Галочка — ваш выбор, строка ниже — статус на момент открытия. Выбор хранится только на телефоне.',
                'The checkmark is your choice. The label below shows the route status when opened. Choices stay on this phone.',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (widget.snapshot.protected)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _t(
                    'Защита включена: прямой обход приостановлен.',
                    'Protection is on: bypass is suspended.',
                  ),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: YurichMobileColors.warning,
                  ),
                ),
              ),
            if (mayReconnect && changed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _t(
                    'При сохранении VPN переподключится. Без блокировки Android возможен краткий перерыв защиты.',
                    'Saving reconnects the VPN. Without Android lockdown, protection may briefly pause.',
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (catalog.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    _t(
                      'Выбрано: $chosen из ${catalog.length}',
                      'Selected: $chosen of ${catalog.length}',
                    ),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (_choiceIds.isNotEmpty)
                    TextButton(
                      key: const ValueKey('smart-route-select-all'),
                      onPressed:
                          widget.snapshot.supported &&
                              _draft.length < _choiceIds.length
                          ? () => setState(() => _draft.addAll(_choiceIds))
                          : null,
                      child: Text(_t('Отметить все', 'Select all')),
                    ),
                ],
              ),
              if (changed)
                Text(
                  _t('Выбор ещё не сохранён.', 'Changes have not been saved.'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: YurichMobileColors.blue,
                  ),
                ),
            ],
            if (installed.isNotEmpty)
              _group(context, _t('На устройстве', 'On this device'), installed),
            if (remaining.isNotEmpty)
              _group(
                context,
                _t('Остальные из каталога', 'More from the catalog'),
                remaining,
              ),
            if (_legacyBuiltIns.isNotEmpty) ...[
              const SizedBox(height: 12),
              Card(
                clipBehavior: Clip.antiAlias,
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: const Border(),
                  collapsedShape: const Border(),
                  title: Text(
                    _t(
                      'Встроенные исключения (${_legacyBuiltIns.length})',
                      'Built-in exceptions (${_legacyBuiltIns.length})',
                    ),
                  ),
                  subtitle: Text(
                    _t(
                      'Уже выбраны, здесь не редактируются',
                      'Already selected; not editable here',
                    ),
                  ),
                  children: [
                    for (final id in _legacyBuiltIns)
                      _row(
                        context,
                        id: id,
                        name: id,
                        availability: null,
                        builtIn: true,
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_t('Отмена', 'Cancel')),
        ),
        FilledButton(
          onPressed: changed && widget.snapshot.supported
              ? () =>
                    Navigator.of(context).pop(Set<String>.unmodifiable(_draft))
              : null,
          child: Text(
            mayReconnect
                ? _t('Сохранить и переподключить', 'Save and reconnect')
                : _t('Сохранить', 'Save'),
          ),
        ),
      ],
    );
  }

  Widget _group(
    BuildContext context,
    String title,
    List<SmartRouteAppCandidate> apps,
  ) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 6),
            child: Text(title, style: Theme.of(context).textTheme.titleSmall),
          ),
        ),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final (index, app) in apps.indexed) ...[
                if (index > 0)
                  const Divider(height: 1, indent: 12, endIndent: 12),
                _row(
                  context,
                  id: app.packageId,
                  name: app.name,
                  availability: app.availability,
                  builtIn: widget.builtInPackages.contains(app.packageId),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );

  Widget _row(
    BuildContext context, {
    required String id,
    required String name,
    required SmartRouteAppAvailability? availability,
    required bool builtIn,
  }) {
    final selected = builtIn || _draft.contains(id);
    final pending = !builtIn && selected != _initial.contains(id);
    final route = widget.snapshot.routeFor(
      id,
      builtIn: builtIn,
      smartRouteEnabled: widget.smartRouteEnabled,
      managedProfile: widget.managedProfile,
      vpnActive: widget.vpnActive,
      availability: availability,
    );
    final statusColor = switch (route) {
      SmartRouteAppRoute.applied => YurichMobileColors.blue,
      SmartRouteAppRoute.protected => YurichMobileColors.warning,
      _ => YurichMobileColors.secondary,
    };
    final textTheme = Theme.of(context).textTheme;
    return CheckboxListTile(
      key: _catalogIds.contains(id) ? ValueKey('smart-route-app-$id') : null,
      controlAffinity: ListTileControlAffinity.trailing,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      value: selected,
      onChanged: !builtIn && widget.snapshot.supported
          ? (checked) => setState(() {
              if (checked == true) {
                _draft.add(id);
              } else {
                _draft.remove(id);
              }
            })
          : null,
      title: Text(name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _status(route),
            style: textTheme.bodySmall?.copyWith(color: statusColor),
          ),
          if (builtIn && _catalogIds.contains(id))
            Text(
              _t('Встроено · не редактируется', 'Built-in · not editable'),
              style: textTheme.bodySmall?.copyWith(
                color: YurichMobileColors.secondary,
              ),
            ),
          if (pending)
            Text(
              selected
                  ? _t('Добавится после сохранения', 'Added on save')
                  : _t('Уберётся после сохранения', 'Removed on save'),
              style: textTheme.bodySmall?.copyWith(
                color: YurichMobileColors.blue,
              ),
            ),
        ],
      ),
    );
  }
}
