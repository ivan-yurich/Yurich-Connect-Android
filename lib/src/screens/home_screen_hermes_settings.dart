part of 'home_screen.dart';

extension _HermesSettings on _HomeScreenState {
  String get _hermesPreviewDescription =>
      !_localIncidents.hermesDeliveryAvailable
      ? s.hermesPreviewHint
      : _language == _AppLanguage.ru
      ? 'Только вымышленный пример. Отправка включается отдельно в настройках.'
      : 'Synthetic example only. Sending requires separate permission in Settings.';

  Future<void> _showHermesSendSettings() async {
    if (!_localIncidents.hermesDeliveryAvailable ||
        _hermesDeliverySettingsOpen ||
        _localIncidentSettingsBusy) {
      return;
    }
    _hermesDeliverySettingsOpen = true;
    var requestedSecureScreen = false;
    final russian = _language == _AppLanguage.ru;
    try {
      final state = await _localIncidents.hermesDeliveryState();
      final local = await _localIncidents.state();
      if (!mounted || _mobilePage != _MobilePage.settings) return;
      _updateHermesLocalSettings(state: local);
      if (state == null) {
        _showSnack(
          russian
              ? 'Настройки отправки недоступны.'
              : 'Sending settings unavailable.',
        );
        return;
      }

      // Also release on a failed/timed-out reply: native may already have
      // installed the flag. Never mount the password field until it confirms.
      requestedSecureScreen = true;
      final secured = await _localIncidents.setHermesSecretScreen(true);
      if (!mounted || _mobilePage != _MobilePage.settings) return;
      if (!secured) {
        _showSnack(
          russian
              ? 'Не удалось защитить экран. Ввод токена недоступен.'
              : 'Could not protect this screen. Token entry is unavailable.',
        );
        return;
      }
      final route = DialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => Theme(
          data: YurichTheme.mobile,
          child: _HermesDeliveryDialog(
            russian: russian,
            localConsent: local?.enabled == true,
            initial: state,
            configure: _configureHermesDelivery,
          ),
        ),
      );
      await Navigator.of(context, rootNavigator: true).push(route);
      // Navigator.push resolves before the reverse transition. Keep the
      // protection until even the dialog's last frame has been removed.
      await route.completed;
    } finally {
      if (requestedSecureScreen) {
        await _localIncidents.setHermesSecretScreen(false);
      }
      _hermesDeliverySettingsOpen = false;
    }
  }

  Future<HermesDeliveryState?> _configureHermesDelivery({
    required bool enabled,
    String? bearer,
  }) async {
    if (!mounted || _localIncidentSettingsBusy) return null;
    _updateHermesLocalSettings(busy: true);
    try {
      final state = await _localIncidents.configureHermesDelivery(
        enabled: enabled,
        bearer: bearer,
      );
      // Revocation rotates the local consent epoch when local storage remains
      // on. Refresh it, so no subsequent record uses the revoked epoch.
      final local = await _localIncidents.state();
      _updateHermesLocalSettings(state: local);
      // Android can commit before the acknowledgement is lost. Show the
      // actual state so that revocation remains available without reopening.
      return state ?? await _localIncidents.hermesDeliveryState();
    } finally {
      _updateHermesLocalSettings(busy: false);
    }
  }
}

class _HermesDeliveryDialog extends StatefulWidget {
  const _HermesDeliveryDialog({
    required this.russian,
    required this.localConsent,
    required this.initial,
    required this.configure,
  });

  final bool russian;
  final bool localConsent;
  final HermesDeliveryState initial;
  final Future<HermesDeliveryState?> Function({
    required bool enabled,
    String? bearer,
  })
  configure;

  @override
  State<_HermesDeliveryDialog> createState() => _HermesDeliveryDialogState();
}

class _HermesDeliveryDialogState extends State<_HermesDeliveryDialog>
    with WidgetsBindingObserver {
  final _bearer = TextEditingController();
  late HermesDeliveryState _state = widget.initial;
  var _consented = false;
  var _busy = false;
  var _failed = false;

  String _t(String russian, String english) =>
      widget.russian ? russian : english;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused) {
      return;
    }
    _bearer.clear();
    if (mounted) setState(() => _consented = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bearer.clear();
    _bearer.dispose();
    super.dispose();
  }

  Future<void> _save(bool enabled) async {
    if (_busy) return;
    if (enabled &&
        (!widget.localConsent ||
            !_consented ||
            !LocalConnectionIncidentsService.isValidHermesBearer(
              _bearer.text,
            ))) {
      return;
    }
    final token = enabled ? _bearer.text : null;
    _bearer.clear();
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _failed = false;
    });
    final result = await widget.configure(enabled: enabled, bearer: token);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result != null) _state = result;
      _failed =
          result == null ||
          result.enabled != enabled ||
          result.tokenConfigured != enabled;
      if (!_failed) _consented = false;
    });
  }

  Future<void> _confirmRevoke() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Отключить отправку?', 'Turn off sending?')),
        content: Text(
          _t(
            'Сохранённый токен и неотправленные отчёты будут удалены. Уже переданные данные отозвать нельзя.',
            'The saved token and unsent reports will be deleted. Data already sent cannot be recalled.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_t('Отмена', 'Cancel')),
          ),
          FilledButton(
            key: const ValueKey('hermes-delivery-revoke-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_t('Отключить и очистить', 'Disable and clear')),
          ),
        ],
      ),
    );
    if (mounted && confirmed == true) await _save(false);
  }

  String get _status {
    if (!_state.enabled) return _t('Отправка выключена.', 'Sending is off.');
    if (_state.authorizationBlocked || !_state.tokenConfigured) {
      return _t(
        'Отправка приостановлена: нужен действующий токен.',
        'Sending is paused: a valid token is required.',
      );
    }
    if (!_state.routeReady) {
      return _t(
        'Отправка разрешена. Отчёты остаются на телефоне, пока Android не подтвердит подходящий маршрут через VPN.',
        'Sending is allowed. Reports stay on this device until Android verifies an eligible VPN route.',
      );
    }
    return _t(
      'Отправка разрешена только через VPN.',
      'Sending is allowed through VPN only.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final validBearer = LocalConnectionIncidentsService.isValidHermesBearer(
      _bearer.text,
    );
    final ready = !_busy && widget.localConsent && _consented && validBearer;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(_t('Отправка отчётов Yurich', 'Send Yurich reports')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_status),
              const SizedBox(height: 12),
              Text(
                _t(
                  'При разрешении обезличенные отчёты, в том числе уже сохранённые, будут автоматически отправляться в Гермес только по подтверждённому VPN-маршруту. На остальных профилях отчёты остаются на телефоне.',
                  'If allowed, sanitized reports, including queued ones, are sent automatically to Hermes over a verified VPN route only. With other profiles, reports stay on this device.',
                ),
              ),
              const SizedBox(height: 12),
              if (!widget.localConsent)
                Text(
                  _t(
                    'Сначала включите локальную запись сбоев в настройках.',
                    'First allow local failure recording in Settings.',
                  ),
                )
              else ...[
                CheckboxListTile(
                  key: const ValueKey('hermes-delivery-consent'),
                  contentPadding: EdgeInsets.zero,
                  value: _consented,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _consented = value == true),
                  title: Text(
                    _t(
                      'Разрешаю отправку в Гермес',
                      'I allow sending to Hermes',
                    ),
                  ),
                ),
                TextField(
                  key: const ValueKey('hermes-delivery-bearer'),
                  controller: _bearer,
                  enabled: !_busy,
                  obscureText: true,
                  enableIMEPersonalizedLearning: false,
                  enableInteractiveSelection: false,
                  enableSuggestions: false,
                  autocorrect: false,
                  autofillHints: null,
                  smartDashesType: SmartDashesType.disabled,
                  smartQuotesType: SmartQuotesType.disabled,
                  // With obscureText Flutter supplies Android's password
                  // variation itself. Do not OR it with VISIBLE_PASSWORD.
                  keyboardType: TextInputType.text,
                  maxLength: LocalConnectionIncidentsService.maxBearerLength,
                  decoration: InputDecoration(
                    labelText: _t(
                      'Отзывной токен Android',
                      'Revocable Android token',
                    ),
                    counterText: '',
                    errorText: _bearer.text.isNotEmpty && !validBearer
                        ? _t(
                            'Введите токен без пробелов и префикса Bearer.',
                            'Enter the token without spaces or the Bearer prefix.',
                          )
                        : null,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ],
              if (_failed) ...[
                const SizedBox(height: 12),
                Text(
                  _t(
                    'Не удалось подтвердить изменение. Проверьте состояние и попробуйте снова.',
                    'Could not confirm the change. Check the state and try again.',
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy
                ? null
                : () {
                    _bearer.clear();
                    Navigator.of(context).pop();
                  },
            child: Text(_t('Закрыть', 'Close')),
          ),
          if (_state.enabled || _state.tokenConfigured)
            TextButton(
              key: const ValueKey('hermes-delivery-revoke'),
              onPressed: _busy ? null : () => unawaited(_confirmRevoke()),
              child: Text(_t('Отключить отправку', 'Turn off sending')),
            ),
          if (widget.localConsent)
            FilledButton(
              key: const ValueKey('hermes-delivery-save'),
              onPressed: ready ? () => unawaited(_save(true)) : null,
              child: Text(
                _state.enabled
                    ? _t('Сменить токен', 'Replace token')
                    : _t('Включить отправку', 'Turn on sending'),
              ),
            ),
        ],
      ),
    );
  }
}
