import 'package:flutter/material.dart';
import '../services/kill_switch_service.dart';

class KillSwitchPanel extends StatelessWidget {
  const KillSwitchPanel({
    super.key,
    required this.state,
    required this.russian,
    required this.busy,
    required this.onSettings,
    required this.onRefresh,
    required this.onApply,
    this.onNormal,
  });

  final KillSwitchState state;
  final bool russian;
  final bool busy;
  final VoidCallback onSettings;
  final VoidCallback onRefresh;
  final VoidCallback onApply;
  final VoidCallback? onNormal;

  @override
  Widget build(BuildContext context) {
    final status = !state.supported
        ? (russian
              ? 'Автопроверка требует Android 10+'
              : 'Automatic verification requires Android 10+')
        : !state.known
        ? (russian ? 'Состояние не подтверждено' : 'State not confirmed')
        : state.fullyConfigured
        ? (russian
              ? 'Включён: Android + строгий TUN'
              : 'Enabled: Android + strict TUN')
        : state.systemEnforced && !state.runtimeKnown
        ? (russian
              ? 'Android блокирует обход; состояние TUN уточняется'
              : 'Android blocks bypass; checking TUN state')
        : state.systemEnforced
        ? (russian
              ? 'Android блокирует обход; примени строгие маршруты'
              : 'Android blocks bypass; apply strict routes')
        : (russian
              ? 'Не настроен: нужна системная блокировка'
              : 'Not configured: system lockdown required');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Kill switch',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(status, key: const ValueKey('kill-switch-status')),
            const SizedBox(height: 8),
            Text(
              russian
                  ? 'При обрыве VPN Android блокирует интернет. Строгий режим — без Smart Route, LAN и исключений; настройки сохраняются.'
                  : 'Android blocks internet if VPN stops. Strict mode suspends Smart Route, LAN and app exceptions; preferences are preserved.',
            ),
            if (state.requested && !state.fullyConfigured)
              Text(
                russian
                    ? 'Запрос строгого режима сохранён; это не подтверждение защиты.'
                    : 'Strict mode is requested; this is not proof of protection.',
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: busy ? null : onSettings,
                  child: Text(
                    russian ? 'Настроить в Android' : 'Set up in Android',
                  ),
                ),
                TextButton(
                  onPressed: busy ? null : onRefresh,
                  child: Text(
                    russian ? 'Проверить защиту' : 'Check protection',
                  ),
                ),
                if (state.systemEnforced &&
                    state.runtimeKnown &&
                    state.vpnActive &&
                    !state.strictRuntime)
                  TextButton(
                    onPressed: busy ? null : onApply,
                    child: Text(
                      russian
                          ? 'Применить строгие маршруты'
                          : 'Apply strict routes',
                    ),
                  ),
                if (state.requested &&
                    (!state.supported ||
                        (state.known && !state.alwaysOn && !state.lockdown)) &&
                    onNormal != null)
                  TextButton(
                    onPressed: busy ? null : onNormal,
                    child: Text(russian ? 'Обычные маршруты' : 'Normal routes'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
