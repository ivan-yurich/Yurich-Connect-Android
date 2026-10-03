import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/on_device_diagnostics.dart';

class DiagnosticsPanel extends StatefulWidget {
  const DiagnosticsPanel({super.key, required this.russian});

  final bool russian;

  @override
  State<DiagnosticsPanel> createState() => _DiagnosticsPanelState();
}

class _DiagnosticsPanelState extends State<DiagnosticsPanel>
    with WidgetsBindingObserver {
  final _service = OnDeviceDiagnosticsService();
  var _run = const DiagnosticRun();
  var _busy = false;
  bool get ru => widget.russian;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final run = await _service.status();
      if (mounted) setState(() => _run = run);
    } on MissingPluginException {
      // Other platforms and older native implementations have no recorder.
    } on Object {
      if (mounted) {
        _notify(
          ru ? 'Не удалось прочитать диагностику' : 'Diagnostics unavailable',
        );
      }
    }
  }

  void _notify(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _toggle(bool enabled) async {
    if (_busy) return;
    if (enabled) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(ru ? 'Диагностика на 7 дней' : '7-day diagnostics'),
          content: Text(
            ru
                ? 'Сохранять на этом телефоне состояния VPN, результаты проверок, смены сети и показатели памяти в течение 7 дней? Пароли, подписки и посещённые сайты не записываются. Данные никуда не отправляются.'
                      '${_run.available ? '\n\nНовый запуск станет текущим отчётом. Сначала экспортируйте предыдущий.' : ''}'
                : 'Record VPN state, health checks, network changes and memory on this phone for 7 days? Passwords, subscriptions and browsing history are excluded. Nothing is uploaded.'
                      '${_run.available ? '\n\nThe new run becomes the current report. Export the previous one first.' : ''}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(ru ? 'Отмена' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(ru ? 'Начать' : 'Start'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final run = enabled ? await _service.start() : await _service.stop();
      if (mounted) setState(() => _run = run);
    } on Object {
      if (mounted) {
        _notify(
          ru ? 'Не удалось изменить режим' : 'Could not change diagnostics',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      if (await _service.export() && mounted) {
        _notify(ru ? 'Отчёт сохранён' : 'Report saved');
      }
    } on Object {
      if (mounted) {
        _notify(ru ? 'Не удалось сохранить отчёт' : 'Could not save report');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final end = _run.endsAt;
    final deadline = end == null
        ? ''
        : '${localizations.formatShortDate(end)} ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(end), alwaysUse24HourFormat: true)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                ru ? 'Диагностика на 7 дней' : '7-day diagnostics',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            Switch(
              value: _run.active,
              onChanged: _busy ? null : (value) => unawaited(_toggle(value)),
            ),
            IconButton(
              tooltip: ru ? 'Экспортировать ZIP' : 'Export ZIP',
              onPressed: !_busy && _run.available
                  ? () => unawaited(_export())
                  : null,
              icon: const Icon(Icons.save_alt),
            ),
          ],
        ),
        Text(
          _run.active
              ? '${ru ? 'До' : 'Until'} $deadline'
              : _run.available
              ? (ru ? 'Завершена' : 'Completed')
              : (ru ? 'Не запущена' : 'Not started'),
        ),
        if (_run.available)
          Text(
            '${ru ? 'Событий' : 'Events'}: ${_run.events}'
            '${_run.rotatedEvents > 0 ? ' · ${ru ? 'Ротация' : 'Rotated'}: ${_run.rotatedEvents}' : ''}',
          ),
      ],
    );
  }
}
