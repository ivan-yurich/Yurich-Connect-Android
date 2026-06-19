import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/connection_status.dart';
import '../models/connection_ui_state.dart';
import '../models/profile_stability.dart';
import '../models/vpn_profile.dart';
import '../services/app_update_service.dart';
import '../services/installed_apps_service.dart';
import '../services/power_manager_service.dart';
import '../services/profile_auto_selector.dart';
import '../services/profile_geo_service.dart';
import '../services/profile_importer.dart';
import '../services/profile_store.dart';
import '../services/protocol_display_mapper.dart';
import '../services/smart_route_rules.dart';
import '../services/sing_box_config_builder.dart';
import '../services/vpn_engine.dart';
import '../theme/yurich_theme.dart';
import '../utils/traffic_formatter.dart';
import 'qr_scan_screen.dart';

const _gold = YurichColors.accentBlue;
const _goldSoft = YurichColors.accentSoft;
const _danger = YurichColors.danger;
const _dangerSoft = YurichColors.dangerSoft;
const _ink = YurichColors.background;
const _surface = YurichColors.surfaceSolid;
const _surfaceMetric = YurichColors.surfaceMetric;
const _mutedGold = YurichColors.textSecondary;
const _cyanGlow = YurichColors.accentCyan;
const _deepGlow = YurichColors.backgroundDeep;
const _appName = 'Yurich Connect';
const _telegramUrl = 'https://t.me/ivan_it_net';
const _vkUrl = 'https://vk.com/ivan_yurievich_it';
const _donateUrl = 'https://dzen.ru/ivanyurievich?donate=true';
const _supportEmail = 'ai@ivan-it.net';
const _appVersionFallback = '1.0.75';
const _nativeShortTimeout = Duration(seconds: 3);
const _nativeConfigTimeout = Duration(seconds: 5);
const _nativeStartTimeout = Duration(seconds: 8);
const _subscriptionReminderWindow = Duration(days: 5);
const _tunnelHealthProbeInterval = Duration(seconds: 105);
const _startupProbeRecheckDelay = Duration(seconds: 8);
const _recentTrafficGrace = Duration(seconds: 120);
const _resumeHealthCheckDelay = Duration(seconds: 2);
const _staleTunnelGrace = Duration(minutes: 5);
const _tunnelHealthFailureThreshold = 4;
const _autoReconnectMaxAttempts = 6;
const _maxStoredLogs = 180;
const _maxPendingLogs = 240;

class _ConnectionConfigPlan {
  const _ConnectionConfigPlan(this.naiveMode, this.label);

  final NaiveOutboundMode naiveMode;
  final String label;
}

enum _AppLanguage {
  ru('ru'),
  en('en');

  const _AppLanguage(this.code);

  final String code;

  static _AppLanguage fromCode(String? code) {
    return values.firstWhere(
      (language) => language.code == code,
      orElse: () => _AppLanguage.ru,
    );
  }
}

enum _ProfileTab { all, vless, naive, hysteria }

enum _SupportTab { help, community }

class _ProfileConnectionBlocked implements Exception {
  const _ProfileConnectionBlocked(this.message);

  final String message;

  @override
  String toString() => message;
}

_ProfileTab _profileTabForKind(VpnProfileKind kind) {
  return switch (kind) {
    VpnProfileKind.vlessReality => _ProfileTab.vless,
    VpnProfileKind.naive => _ProfileTab.naive,
    VpnProfileKind.hysteria2 || VpnProfileKind.hysteria => _ProfileTab.hysteria,
    VpnProfileKind.vlessTls ||
    VpnProfileKind.vlessXhttp ||
    VpnProfileKind.vlessMkcp ||
    VpnProfileKind.singBoxConfig => _ProfileTab.all,
  };
}

bool _profileMatchesTab(VpnProfile profile, _ProfileTab tab) {
  return tab == _ProfileTab.all || _profileTabForKind(profile.kind) == tab;
}

List<VpnProfile> _clientSupportedProfiles(List<VpnProfile> profiles) {
  return profiles
      .where((profile) => profile.kind.isClientSupported)
      .toList(growable: false);
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _vpnEngine = createVpnEngine();
  final _store = ProfileStore();
  final _importer = ProfileImporter();
  final _configBuilder = SingBoxConfigBuilder();
  final _autoSelector = const ProfileAutoSelector();
  final _updateService = AppUpdateService();
  final _powerManagerService = PowerManagerService();
  final _geoService = ProfileGeoService();
  final _installedAppsService = InstalledAppsService();
  final _manualController = TextEditingController();

  StreamSubscription<Map<String, dynamic>>? _statusSubscription;
  StreamSubscription<Map<String, dynamic>>? _trafficSubscription;
  StreamSubscription<Map<String, dynamic>>? _logSubscription;
  Timer? _logFlushTimer;
  Timer? _trafficFlushTimer;
  Timer? _statusWatchdogTimer;
  Timer? _uptimeTimer;
  Timer? _subscriptionReminderTimer;
  DateTime? _ignoreStoppedUntil;
  DateTime? _connectedSince;
  DateTime? _lastTrafficAt;
  DateTime? _lastHealthyAt;
  DateTime? _lastKeeperActionAt;
  DateTime _clockNow = DateTime.now();
  Map<String, dynamic>? _latestTrafficEvent;

  List<VpnProfile> _profiles = const [];
  final _profilePingMs = <String, int>{};
  final _profilePingText = <String, String>{};
  final _profilePingBusy = <String, bool>{};
  final _profilePingError = <String, String>{};
  Map<String, ProfileStabilityStats> _profileStabilityStats = const {};
  String? _selectedProfileId;
  _AppLanguage _language = _AppLanguage.ru;
  _ProfileTab _profileTab = _ProfileTab.all;
  bool _profilesExpanded = false;
  _SupportTab _supportTab = _SupportTab.help;
  String _status = AurumVpnStatus.stopped;
  String _uplink = '0 B/s';
  String _downlink = '0 B/s';
  String _sessionTotal = '0 B';
  String _message = 'Готов к импорту подписки';
  String _appVersion = _appVersionFallback;
  String _appBuildNumber = '';
  String? _lastError;
  bool _busy = false;
  bool _updateBusy = false;
  bool _subscriptionRefreshBusy = false;
  bool _stoppingByUser = false;
  bool _statusWatchdogInFlight = false;
  bool _tunnelHealthCheckInFlight = false;
  bool _autoReconnectInFlight = false;
  bool _notificationSyncInFlight = false;
  bool _autoRecoveryArmed = false;
  bool _pingAllInFlight = false;
  bool _countryResolveInFlight = false;
  bool _logsExpanded = false;
  String? _lastConfigSummary;
  String? _lastKeeperAction;
  String? _updateMessage;
  AppUpdateInfo? _availableUpdate;
  double? _updateProgress;
  bool _updateNoticeShown = false;
  bool _batteryOptimizationIgnored = true;
  bool _batteryOptimizationCheckInFlight = false;
  bool _batteryOptimizationPromptShown = false;
  bool _smartRouteRuDirect = false;
  DateTime? _nextAutoReconnectAt;
  DateTime? _nextTunnelHealthCheckAt;
  int _autoReconnectAttempts = 0;
  int _tunnelHealthFailures = 0;
  int _lastSessionTrafficBytes = 0;
  final _logs = <String>[];
  final _pendingLogs = <String>[];
  late final AnimationController _glowController;
  late final Animation<double> _glowPulse;

  _Strings get s => _Strings.forLanguage(_language);

  Duration? get _connectedDuration {
    final since = _connectedSince;
    if (since == null || _status != AurumVpnStatus.started) {
      return null;
    }
    final duration = _clockNow.difference(since);
    return duration.isNegative ? Duration.zero : duration;
  }

  String get _keeperStatusLabel {
    if (!_autoRecoveryArmed) {
      return s.keeperIdle;
    }
    if (_autoReconnectInFlight) {
      return s.keeperReconnecting;
    }
    if (_tunnelHealthCheckInFlight) {
      return s.keeperChecking;
    }
    if (_connectionDegraded) {
      return s.keeperDegraded;
    }
    return s.keeperActive;
  }

  String get _lastHealthStatusLabel {
    final lastHealthyAt = _lastHealthyAt;
    if (lastHealthyAt == null) {
      return s.lastCheckNever;
    }
    return s.lastCheckAgo(_clockNow.difference(lastHealthyAt));
  }

  String get _autoRecoveryStatusLabel =>
      _autoRecoveryArmed ? s.autoRecoveryOn : s.autoRecoveryOff;

  String get _healthFailuresStatusLabel => _tunnelHealthFailures == 0
      ? s.healthFailuresNone
      : s.healthFailuresCount(_tunnelHealthFailures);

  VpnProfile? get _selectedProfile {
    for (final profile in _profiles) {
      if (profile.id == _selectedProfileId) {
        return profile;
      }
    }
    return _profiles.isEmpty ? null : _profiles.first;
  }

  bool get _connected =>
      _status == AurumVpnStatus.started || _status == AurumVpnStatus.starting;

  bool get _connectionDegraded {
    if (_stoppingByUser) {
      return false;
    }
    if (_autoReconnectInFlight || _tunnelHealthFailures > 0) {
      return true;
    }
    if (_autoRecoveryArmed && _lastError != null && _lastError!.isNotEmpty) {
      return true;
    }
    if (_autoRecoveryArmed && _status == AurumVpnStatus.stopped) {
      return true;
    }
    if (_status == AurumVpnStatus.started) {
      if (_isTunnelStale(DateTime.now())) {
        return true;
      }
    }
    return false;
  }

  bool _isTunnelStale(DateTime now) {
    if (_status != AurumVpnStatus.started || !_autoRecoveryArmed) {
      return false;
    }

    final lastHealthyAt = _lastHealthyAt;
    if (lastHealthyAt != null) {
      return now.difference(lastHealthyAt) > _staleTunnelGrace;
    }

    final lastTrafficAt = _lastTrafficAt;
    if (lastTrafficAt != null) {
      return now.difference(lastTrafficAt) > _staleTunnelGrace;
    }

    final connectedSince = _connectedSince;
    if (connectedSince == null) {
      return true;
    }
    return now.difference(connectedSince) > _staleTunnelGrace;
  }

  int _healthProbeAttemptsFor(String source) {
    if (source == 'app-resume' ||
        source.contains('stale') ||
        _tunnelHealthFailures > 0) {
      return 2;
    }
    return 1;
  }

  void _setKeeperAction(String action, {DateTime? at}) {
    _lastKeeperAction = action;
    _lastKeeperActionAt = at ?? DateTime.now();
  }

  ConnectionUiState get _connectionUiState {
    final profile = _selectedProfile;
    final connectionStatus = switch (_status) {
      AurumVpnStatus.started => ConnectionStatus.connected,
      AurumVpnStatus.starting ||
      AurumVpnStatus.stopping => ConnectionStatus.connecting,
      _ => ConnectionStatus.disconnected,
    };

    if (connectionStatus == ConnectionStatus.disconnected) {
      return ConnectionUiState.disconnected();
    }

    return ConnectionUiState(
      status: connectionStatus,
      profileName: profile == null ? null : _profileDisplayName(profile),
      protocolDisplayName: profile == null
          ? null
          : ProtocolDisplayMapper.mapProfile(profile),
      countryName: _profileCountryName(profile),
      countryCode: profile?.countryCode,
      pingMs: profile == null ? null : _profilePingMs[profile.id],
      uploadSpeed: _uplink,
      downloadSpeed: _downlink,
      totalTraffic: _sessionTotal,
      sessionDuration: _connectedDuration == null
          ? null
          : TrafficFormatter.formatDuration(_connectedDuration!),
    );
  }

  String? _profileCountryName(VpnProfile? profile) {
    if (profile == null) {
      return null;
    }
    final countryName = profile.countryName?.trim();
    if (countryName != null && countryName.isNotEmpty) {
      return countryName;
    }
    final flag = _profileCountryFlag(profile);
    return switch (flag) {
      '🇷🇺' => 'Россия',
      '🇫🇮' => 'Финляндия',
      '🇩🇪' => 'Германия',
      '🇺🇸' => 'США',
      '🇯🇵' => 'Япония',
      '🇳🇱' => 'Нидерланды',
      '🇫🇷' => 'Франция',
      '🇨🇦' => 'Канада',
      '🇹🇷' => 'Турция',
      '🇬🇧' => 'Великобритания',
      _ => null,
    };
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
    _glowPulse = CurvedAnimation(
      parent: _glowController,
      curve: Curves.easeInOut,
    );
    _load();
    _initVpn();
    _statusWatchdogTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => unawaited(_refreshStatusWatchdog()),
    );
    _uptimeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _status != AurumVpnStatus.started) {
        return;
      }
      setState(() => _clockNow = DateTime.now());
    });
    _subscriptionReminderTimer = Timer.periodic(
      const Duration(hours: 6),
      (_) => unawaited(_showSubscriptionRenewalReminder(_profiles)),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_refreshBatteryOptimizationStatus(prompt: true));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusSubscription?.cancel();
    _trafficSubscription?.cancel();
    _logSubscription?.cancel();
    _logFlushTimer?.cancel();
    _trafficFlushTimer?.cancel();
    _statusWatchdogTimer?.cancel();
    _uptimeTimer?.cancel();
    _subscriptionReminderTimer?.cancel();
    _manualController.dispose();
    _glowController.dispose();
    unawaited(_vpnEngine.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshBatteryOptimizationStatus());
      unawaited(_handleResumeRecovery());
    }
  }

  Future<void> _handleResumeRecovery() async {
    await Future<void>.delayed(_resumeHealthCheckDelay);
    if (!mounted || _stoppingByUser || !_autoRecoveryArmed) {
      return;
    }

    final status = await _refreshVpnStatus();
    if (!mounted || _stoppingByUser || !_autoRecoveryArmed) {
      return;
    }

    if (status == AurumVpnStatus.stopped) {
      _markUnexpectedStop('app-resume');
      return;
    }

    if (status == AurumVpnStatus.started) {
      _nextTunnelHealthCheckAt = DateTime.now();
      unawaited(_refreshTunnelHealth(source: 'app-resume'));
    }
  }

  Future<void> _load() async {
    final appInfo = await _loadAppInfo();
    final storedProfiles = await _store.loadProfiles();
    final profiles = _clientSupportedProfiles(storedProfiles);
    final loadedStabilityStats = await _store.loadProfileStabilityStats();
    if (profiles.length != storedProfiles.length) {
      await _store.saveProfiles(profiles);
    }
    final selectedId = await _store.loadSelectedProfileId();
    final language = _AppLanguage.fromCode(await _store.loadLanguageCode());
    final smartRouteRuDirect = await _store.loadSmartRouteRuDirect();
    if (!mounted) {
      return;
    }
    final strings = _Strings.forLanguage(language);
    final profileIds = profiles.map((profile) => profile.id).toSet();
    final stabilityStats = Map<String, ProfileStabilityStats>.fromEntries(
      loadedStabilityStats.entries.where(
        (entry) => profileIds.contains(entry.key),
      ),
    );
    if (stabilityStats.length != loadedStabilityStats.length) {
      await _store.saveProfileStabilityStats(stabilityStats);
      if (!mounted) {
        return;
      }
    }
    final resolvedSelectedId =
        profiles.any((profile) => profile.id == selectedId)
        ? selectedId
        : (profiles.isEmpty ? null : profiles.first.id);
    setState(() {
      _language = language;
      _appVersion = appInfo.version;
      _appBuildNumber = appInfo.buildNumber;
      _profiles = profiles;
      _profileStabilityStats = stabilityStats;
      _selectedProfileId = resolvedSelectedId;
      _smartRouteRuDirect = smartRouteRuDirect;
      _message = profiles.isEmpty
          ? strings.addProfileHint
          : strings.loadedProfiles(profiles.length);
    });
    unawaited(_pingProfiles(profiles));
    unawaited(_resolveProfileCountries(profiles));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_showSubscriptionRenewalReminder(profiles));
        unawaited(_checkLatestUpdateNotice());
      }
    });
  }

  Future<({String version, String buildNumber})> _loadAppInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return (
        version: info.version.trim().isEmpty
            ? _appVersionFallback
            : info.version,
        buildNumber: info.buildNumber,
      );
    } on Object {
      return (version: _appVersionFallback, buildNumber: '');
    }
  }

  Future<void> _initVpn() async {
    _statusSubscription = _vpnEngine.onStatusChanged.listen(
      (event) {
        try {
          if (event['type'] == 'alert') {
            final message = event['message'] as String?;
            if (message != null && message.isNotEmpty && mounted) {
              setState(() => _message = message);
              _showSnack(message);
            }
            return;
          }

          final status = event['status'] as String?;
          if (status != null && mounted) {
            final now = DateTime.now();
            var recoverUnexpectedStop = false;
            setState(() {
              _status = status;
              if (status == AurumVpnStatus.started) {
                _lastError = null;
                _autoReconnectAttempts = 0;
                _nextAutoReconnectAt = null;
                _autoRecoveryArmed = true;
                _connectedSince ??= now;
                _lastHealthyAt = now;
                _lastTrafficAt ??= now;
                _clockNow = now;
                _ignoreStoppedUntil = now.add(const Duration(seconds: 4));
              }
              if (status == AurumVpnStatus.stopped && !_autoRecoveryArmed) {
                _connectedSince = null;
                _lastTrafficAt = null;
                _lastHealthyAt = null;
              }
              final ignoreStopped =
                  _ignoreStoppedUntil != null &&
                  now.isBefore(_ignoreStoppedUntil!);
              if (status == AurumVpnStatus.stopped &&
                  _autoRecoveryArmed &&
                  !_stoppingByUser &&
                  !ignoreStopped) {
                recoverUnexpectedStop = true;
              }
            });
            if (recoverUnexpectedStop) {
              _markUnexpectedStop('status-event');
            }
            unawaited(_syncConnectionNotification());
          }
        } on Object catch (error, stackTrace) {
          _handleEngineStreamError('status', error, stackTrace);
        }
      },
      onError: (Object error, StackTrace stackTrace) =>
          _handleEngineStreamError('status', error, stackTrace),
      cancelOnError: false,
    );

    _trafficSubscription = _vpnEngine.onTrafficUpdate.listen(
      (event) {
        try {
          if (!mounted) {
            return;
          }
          _latestTrafficEvent = event;
          _trafficFlushTimer ??= Timer(const Duration(milliseconds: 500), () {
            try {
              _trafficFlushTimer = null;
              final latest = _latestTrafficEvent;
              _latestTrafficEvent = null;
              if (!mounted || latest == null) {
                return;
              }
              final uplinkSpeed = _eventInt(latest['uplinkSpeed']);
              final downlinkSpeed = _eventInt(latest['downlinkSpeed']);
              final sessionTotal = _eventInt(latest['sessionTotal']);
              final hasTraffic =
                  uplinkSpeed > 0 ||
                  downlinkSpeed > 0 ||
                  sessionTotal > _lastSessionTrafficBytes;
              final now = DateTime.now();
              setState(() {
                _uplink = latest['formattedUplinkSpeed'] as String? ?? _uplink;
                _downlink =
                    latest['formattedDownlinkSpeed'] as String? ?? _downlink;
                _sessionTotal =
                    latest['formattedSessionTotal'] as String? ?? _sessionTotal;
                if (sessionTotal >= _lastSessionTrafficBytes) {
                  _lastSessionTrafficBytes = sessionTotal;
                }
                if (hasTraffic && _status == AurumVpnStatus.started) {
                  _lastTrafficAt = now;
                  _lastHealthyAt = now;
                  _tunnelHealthFailures = 0;
                }
              });
              unawaited(_syncConnectionNotification());
            } on Object catch (error, stackTrace) {
              _handleEngineStreamError('traffic-flush', error, stackTrace);
            }
          });
        } on Object catch (error, stackTrace) {
          _handleEngineStreamError('traffic', error, stackTrace);
        }
      },
      onError: (Object error, StackTrace stackTrace) =>
          _handleEngineStreamError('traffic', error, stackTrace),
      cancelOnError: false,
    );

    try {
      await _bestEffortNative(
        'setNotificationTitle',
        _vpnEngine.setNotificationTitle(_appName),
      );
      await _bestEffortNative(
        'setNotificationDescription',
        _vpnEngine.setNotificationDescription(s.notificationDescription),
      );
      await _bestEffortNative(
        'requestNotificationPermission',
        _vpnEngine.requestNotificationPermission(),
      );
      final status = await _vpnEngine.getVPNStatus().timeout(
        _nativeShortTimeout,
        onTimeout: () => _status,
      );
      final bufferedLogs = await _vpnEngine.getLogs().timeout(
        const Duration(seconds: 2),
        onTimeout: () => const <String>[],
      );
      if (mounted) {
        setState(() {
          _status = status;
          if (status == AurumVpnStatus.started) {
            _autoRecoveryArmed = true;
            _connectedSince ??= DateTime.now();
            _clockNow = DateTime.now();
          } else if (status == AurumVpnStatus.stopped) {
            _autoRecoveryArmed = false;
            _connectedSince = null;
          }
          _logs
            ..clear()
            ..addAll(
              bufferedLogs
                  .map(_cleanLog)
                  .where((log) => log.isNotEmpty)
                  .toList()
                  .reversed
                  .take(_maxStoredLogs)
                  .toList()
                  .reversed,
            );
        });
        unawaited(_syncConnectionNotification());
      }
    } on Object {
      // In widget tests and desktop preview the native Android plugin is absent.
    }
  }

  void _handleEngineStreamError(
    String source,
    Object error, [
    StackTrace? stackTrace,
  ]) {
    final errorText = _redactSensitive('$error');
    _queueLog('Engine stream error [$source]: $errorText');
    if (stackTrace != null) {
      _queueLog('Engine stream stack [$source]: $stackTrace');
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _lastError = errorText;
      if (_status == AurumVpnStatus.started) {
        _tunnelHealthFailures += 1;
      }
    });
  }

  Future<void> _syncConnectionNotification() async {
    if (_notificationSyncInFlight) {
      return;
    }
    _notificationSyncInFlight = true;
    try {
      await _bestEffortNative(
        'updateConnectionNotification',
        _vpnEngine.updateConnectionNotification(_connectionUiState.toJson()),
        timeout: const Duration(seconds: 2),
      );
    } finally {
      _notificationSyncInFlight = false;
    }
  }

  Future<void> _refreshBatteryOptimizationStatus({bool prompt = false}) async {
    if (!Platform.isAndroid || _batteryOptimizationCheckInFlight) {
      return;
    }
    _batteryOptimizationCheckInFlight = true;
    try {
      final ignored = await _powerManagerService
          .isIgnoringBatteryOptimizations()
          .timeout(const Duration(seconds: 2), onTimeout: () => true);
      if (!mounted) {
        return;
      }
      setState(() => _batteryOptimizationIgnored = ignored);
      if (!ignored && prompt && !_batteryOptimizationPromptShown) {
        _batteryOptimizationPromptShown = true;
        _showSnack(
          s.batteryOptimizationSnack,
          action: SnackBarAction(
            label: s.backgroundModeRequest,
            onPressed: () => unawaited(_requestBackgroundPowerAccess()),
          ),
        );
      }
    } finally {
      _batteryOptimizationCheckInFlight = false;
    }
  }

  Future<void> _requestBackgroundPowerAccess() async {
    await _powerManagerService.requestIgnoreBatteryOptimizations();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _refreshBatteryOptimizationStatus();
    if (mounted) {
      _showSnack(s.batteryOptimizationOpened);
    }
  }

  Future<void> _importManual() async {
    await _importText(_manualController.text);
  }

  Future<void> _importFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    await _importText(text);
  }

  Future<void> _importFromQr() async {
    final value = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (value == null || value.trim().isEmpty) {
      return;
    }
    await _importText(value);
  }

  Future<void> _showImportSheet() async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
        return AnimatedPadding(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: EdgeInsets.fromLTRB(18, 24, 18, 24 + bottomInset),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Material(
                color: _surface,
                elevation: 18,
                shadowColor: YurichColors.shadow,
                borderRadius: BorderRadius.circular(YurichRadii.card),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              s.addProfile,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          IconButton(
                            tooltip: s.close,
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _manualController,
                        minLines: 3,
                        maxLines: 6,
                        decoration: InputDecoration(hintText: s.importHint),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          FilledButton.icon(
                            onPressed: _busy
                                ? null
                                : () {
                                    Navigator.of(context).pop();
                                    unawaited(_importManual());
                                  },
                            icon: const Icon(Icons.add_link),
                            label: Text(s.importAction),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () {
                                    Navigator.of(context).pop();
                                    unawaited(_importFromClipboard());
                                  },
                            icon: const Icon(Icons.content_paste),
                            label: Text(s.clipboard),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () {
                                    Navigator.of(context).pop();
                                    unawaited(_importFromQr());
                                  },
                            icon: const Icon(Icons.qr_code_scanner),
                            label: const Text('QR'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _importText(String text) async {
    await _runBusy(() async {
      final subscriptionSource = ProfileStore.subscriptionSourceKeyFromText(
        text,
      );
      final imported = _clientSupportedProfiles(
        await _importer.importFromText(text),
      );
      if (imported.isEmpty) {
        throw ProfileImportException(s.supportedProtocolsOnly);
      }

      if (subscriptionSource != null) {
        await _store.clearDeletedProfilesForSubscriptionSource(
          subscriptionSource,
        );
      }
      final importedWithCachedData = _profilesWithCachedData(imported);
      final merged = _mergeProfiles(importedWithCachedData);

      await _store.saveProfiles(merged);
      await _store.saveSelectedProfileId(importedWithCachedData.first.id);
      _manualController.clear();

      if (!mounted) {
        return;
      }
      setState(() {
        _profiles = merged;
        _selectedProfileId = importedWithCachedData.first.id;
        _profileTab = _profileTabForKind(importedWithCachedData.first.kind);
        _message = s.imported(imported.length);
      });
      unawaited(_pingProfiles(merged));
      unawaited(_resolveProfileCountries(merged));
      unawaited(_showSubscriptionRenewalReminder(merged, force: true));
      _showSnack(s.importedProfiles(imported.length));
    });
  }

  List<VpnProfile> _profilesWithCachedData(List<VpnProfile> profiles) {
    final existingById = {for (final profile in _profiles) profile.id: profile};

    return profiles
        .map((profile) {
          final existing = existingById[profile.id];
          if (existing == null) {
            return profile;
          }
          return profile.copyWith(
            subscriptionExpiresAt:
                profile.subscriptionExpiresAt ?? existing.subscriptionExpiresAt,
            subscriptionSource:
                profile.subscriptionSource ?? existing.subscriptionSource,
            countryCode: profile.countryCode ?? existing.countryCode,
            countryName: profile.countryName ?? existing.countryName,
          );
        })
        .toList(growable: false);
  }

  List<VpnProfile> _mergeProfiles(List<VpnProfile> profiles) {
    return _clientSupportedProfiles(
      <String, VpnProfile>{
        for (final profile in _profiles) profile.id: profile,
        for (final profile in profiles) profile.id: profile,
      }.values.toList(),
    );
  }

  List<String> _subscriptionSourcesFor(List<VpnProfile> profiles) {
    final sources = <String>{};
    for (final profile in profiles) {
      final source = ProfileStore.subscriptionSourceKeyFor(profile);
      if (source != null) {
        sources.add(source);
      }
    }
    return sources.toList(growable: false);
  }

  List<VpnProfile> _withoutDeletedSubscriptionProfiles(
    List<VpnProfile> profiles,
    Map<String, Set<String>> deletedBySource,
  ) {
    if (deletedBySource.isEmpty) {
      return profiles;
    }

    return profiles
        .where((profile) {
          final source = ProfileStore.subscriptionSourceKeyFor(profile);
          if (source == null) {
            return true;
          }
          return !(deletedBySource[source]?.contains(profile.id) ?? false);
        })
        .toList(growable: false);
  }

  Future<void> _refreshSubscriptions() async {
    if (_busy || _subscriptionRefreshBusy) {
      return;
    }

    final sources = _subscriptionSourcesFor(_profiles);
    if (sources.isEmpty) {
      _showSnack(s.noSubscriptionsToRefresh);
      unawaited(_showImportSheet());
      return;
    }

    setState(() {
      _subscriptionRefreshBusy = true;
      _message = s.refreshingSubscriptions;
    });

    try {
      final deletedBySource = await _store
          .loadDeletedProfileIdsBySubscriptionSource();
      final imported = <VpnProfile>[];
      Object? lastError;
      for (final source in sources) {
        try {
          imported.addAll(
            _clientSupportedProfiles(await _importer.importFromText(source)),
          );
        } on Object catch (error) {
          lastError = error;
          _queueLog(
            'Subscription refresh failed: ${_redactSensitive(source)} | '
            '${_redactSensitive('$error')}',
          );
        }
      }

      if (imported.isEmpty) {
        throw ProfileImportException(
          s.subscriptionRefreshFailed(
            _redactSensitive('${lastError ?? s.nothingToImport}'),
          ),
        );
      }

      final importedWithCachedData = _profilesWithCachedData(imported);
      final visibleImported = _withoutDeletedSubscriptionProfiles(
        importedWithCachedData,
        deletedBySource,
      );
      final merged = _mergeProfiles(visibleImported);
      final selectedId =
          _selectedProfileId != null &&
              merged.any((profile) => profile.id == _selectedProfileId)
          ? _selectedProfileId
          : (merged.isEmpty ? null : merged.first.id);

      await _store.saveProfiles(merged);
      await _store.saveSelectedProfileId(selectedId);
      if (!mounted) {
        return;
      }

      setState(() {
        _profiles = merged;
        _selectedProfileId = selectedId;
        _message = s.subscriptionsUpdated(visibleImported.length);
      });
      unawaited(_pingProfiles(merged));
      unawaited(_resolveProfileCountries(merged));
      unawaited(_showSubscriptionRenewalReminder(merged, force: true));
      _showSnack(s.subscriptionsUpdated(visibleImported.length));
    } on Object catch (error) {
      final errorText = _redactSensitive('$error');
      if (mounted) {
        setState(() {
          _lastError = errorText;
          _message = errorText;
        });
        _showSnack(errorText);
      }
    } finally {
      if (mounted) {
        setState(() => _subscriptionRefreshBusy = false);
      }
    }
  }

  bool _subscriptionNeedsAttention(VpnProfile profile) {
    final expiresAt = profile.subscriptionExpiresAt;
    if (expiresAt == null) {
      return false;
    }

    final remaining = expiresAt.toUtc().difference(DateTime.now().toUtc());
    return remaining <= _subscriptionReminderWindow;
  }

  String? _subscriptionTileStatus(VpnProfile profile) {
    if (profile.subscriptionExpiresAt == null) {
      return null;
    }
    return s.subscriptionStatus(profile.subscriptionExpiresAt);
  }

  List<VpnProfile> _subscriptionReminderProfiles(List<VpnProfile> profiles) {
    final warnedBySource = <String>{};
    final due = <VpnProfile>[];
    for (final profile in profiles) {
      if (!_subscriptionNeedsAttention(profile)) {
        continue;
      }

      final source = (profile.subscriptionSource ?? profile.originalInput)
          .trim();
      final sourceKey = source.isNotEmpty ? source : profile.id;
      if (!warnedBySource.add(sourceKey)) {
        continue;
      }
      due.add(profile);
    }

    due.sort((a, b) {
      final left =
          a.subscriptionExpiresAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final right =
          b.subscriptionExpiresAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return left.compareTo(right);
    });
    return due;
  }

  Future<void> _showSubscriptionRenewalReminder(
    List<VpnProfile> profiles, {
    bool force = false,
  }) async {
    if (!mounted || profiles.isEmpty) {
      return;
    }

    final due = _subscriptionReminderProfiles(profiles);
    if (due.isEmpty) {
      return;
    }

    final primary = due.first;
    final expiresAt = primary.subscriptionExpiresAt;
    if (expiresAt == null) {
      return;
    }

    final localDay = DateTime.now()
        .toLocal()
        .toIso8601String()
        .split('T')
        .first;
    final stamp =
        '$localDay|${primary.subscriptionSource ?? (primary.originalInput.isEmpty ? primary.id : primary.originalInput)}|${expiresAt.toUtc().toIso8601String()}';
    if (!force && await _store.loadSubscriptionReminderStamp() == stamp) {
      return;
    }

    final profileName = _profileDisplayName(primary);
    final status = s.subscriptionStatus(expiresAt);
    final body = due.length == 1
        ? s.subscriptionReminderBody(profileName, status)
        : s.subscriptionReminderMany(due.length, profileName, status);

    await _store.saveSubscriptionReminderStamp(stamp);
    _showSnack(body);

    try {
      await _vpnEngine.requestNotificationPermission().timeout(
        _nativeShortTimeout,
      );
      final shown = await _vpnEngine
          .showAppNotification(
            title: s.subscriptionReminderTitle,
            body: body,
            id: 7039,
          )
          .timeout(_nativeShortTimeout);
      if (!shown) {
        _queueLog('Subscription reminder notification skipped: permission');
      }
    } on Object catch (error) {
      _queueLog(
        'Subscription reminder notification failed: '
        '${_redactSensitive('$error')}',
      );
    }
  }

  Future<void> _toggleVpn() async {
    if (_connected) {
      await _disconnect();
    } else {
      await _connect();
    }
  }

  Future<void> _selectProfile(VpnProfile profile) async {
    if (_busy) {
      return;
    }

    final current = _selectedProfile;
    if (current?.id == profile.id) {
      return;
    }

    final blockReason = _profileConnectBlockReason(profile);
    if (_connected && blockReason != null) {
      _queueLog(
        'Profile switch blocked for ${profile.kind.label}: $blockReason',
      );
      setState(() => _message = blockReason);
      _showSnack(blockReason);
      return;
    }

    if (!_connected) {
      setState(() {
        _selectedProfileId = profile.id;
        _message = blockReason ?? s.selectedProfile(profile.name);
      });
      await _store.saveSelectedProfileId(profile.id);
      unawaited(_pingProfile(profile));
      if (blockReason != null) {
        _showSnack(blockReason);
      }
      return;
    }

    await _runBusy(() async {
      await _stopVpnCore(updateMessage: false);
      await _startVpnCore(profile);
    }, message: s.switchingProfile);
  }

  Future<void> _connect() async {
    final profile = _autoConnectProfile();
    if (profile == null) {
      _showSnack(
        _profiles.isEmpty ? s.importFirst : s.autoConnectNoStableProfile,
      );
      return;
    }

    final blockReason = _profileConnectBlockReason(profile);
    if (blockReason != null) {
      _queueLog('Connection blocked for ${profile.kind.label}: $blockReason');
      setState(() {
        _lastError = blockReason;
        _message = blockReason;
      });
      _showSnack(blockReason);
      return;
    }

    unawaited(_refreshBatteryOptimizationStatus(prompt: true));
    _autoRecoveryArmed = true;
    await _runBusy(() async {
      try {
        if (_selectedProfileId != profile.id) {
          setState(() {
            _selectedProfileId = profile.id;
            _profileTab = _profileTabForKind(profile.kind);
            _profilesExpanded = false;
            _message = s.autoSelectedProfile(profile.name);
          });
          await _store.saveSelectedProfileId(profile.id);
        }
        await _startVpnCore(profile);
      } on Object catch (error) {
        _autoRecoveryArmed = false;
        unawaited(
          _recordProfileStability(
            profile,
            (stats) => stats.recordStartFailure(_redactSensitive('$error')),
          ),
        );
        rethrow;
      }
    }, message: s.connectingTo(profile.name));
  }

  VpnProfile? _autoConnectProfile() {
    return _autoSelector.choose(
      _profiles,
      selectedProfileId: _selectedProfileId,
      pingMs: _profilePingMs,
      offlineProfileIds: _profilePingError.keys.toSet(),
      stabilityStats: _profileStabilityStats,
    );
  }

  ProfileStabilityStats _profileStabilityFor(String profileId) {
    return _profileStabilityStats[profileId] ?? const ProfileStabilityStats();
  }

  Future<void> _recordProfileStability(
    VpnProfile profile,
    ProfileStabilityStats Function(ProfileStabilityStats current) update,
  ) async {
    final nextStats = Map<String, ProfileStabilityStats>.from(
      _profileStabilityStats,
    );
    nextStats[profile.id] = update(_profileStabilityFor(profile.id));
    if (mounted) {
      setState(() => _profileStabilityStats = nextStats);
    } else {
      _profileStabilityStats = nextStats;
    }
    await _store.saveProfileStabilityStats(nextStats);
  }

  String _profileStabilityLabel(VpnProfile profile) {
    final stats = _profileStabilityFor(profile.id);
    if (stats.isTemporarilyUnstable()) {
      return s.profileStabilityCoolingDown;
    }
    final penalty = stats.autoSelectPenalty();
    if (penalty >= 420) {
      return s.profileStabilityWeak;
    }
    if (stats.successfulStarts > 0 && penalty <= 80) {
      return s.profileStabilityGood;
    }
    return s.profileStabilityLearning;
  }

  Future<void> _startVpnCore(VpnProfile profile) async {
    final blockReason = _profileConnectBlockReason(profile);
    if (blockReason != null) {
      throw _ProfileConnectionBlocked(blockReason);
    }

    _ignoreStoppedUntil = DateTime.now().add(const Duration(seconds: 18));
    final status = await _refreshVpnStatus();
    if (status != AurumVpnStatus.stopped) {
      await _stopVpnCore(updateMessage: false);
    }

    await Future<void>.delayed(const Duration(milliseconds: 1400));

    _pendingLogs.clear();
    _logs.clear();
    _lastError = null;
    _lastTrafficAt = null;
    _lastHealthyAt = null;
    _lastSessionTrafficBytes = 0;
    _tunnelHealthFailures = 0;
    await _bestEffortNative('clearLogs', _vpnEngine.clearLogs());

    await _bestEffortNative(
      'requestNotificationPermission',
      _vpnEngine.requestNotificationPermission(),
    );

    Object? lastStartError;
    var connected = false;
    var startupProbeDegraded = false;
    final plans = _connectionPlans(profile);
    final smartRouteBypassPackages = await _smartRouteBypassPackages();

    for (
      var planIndex = 0;
      planIndex < plans.length && !connected;
      planIndex += 1
    ) {
      final plan = plans[planIndex];
      final config = _configBuilder.build(
        profile,
        naiveMode: plan.naiveMode,
        smartRouteRuDirect: _smartRouteRuDirect,
        smartRouteRuBypassPackages: smartRouteBypassPackages,
      );
      final configSummary = _summarizeSingBoxConfig(
        config,
        target: _vpnEngine.configTarget,
      );
      final saved = await _nativeCall(
        'saveConfig',
        _vpnEngine.saveConfig(config),
        timeout: _nativeConfigTimeout,
      );
      if (!saved) {
        throw StateError(s.configSaveFailed);
      }

      for (var attempt = 1; attempt <= 2 && !connected; attempt += 1) {
        if (mounted) {
          setState(() {
            _selectedProfileId = profile.id;
            _lastError = null;
            _message = plans.length > 1
                ? '${s.connectingStatus(profile.name)} · ${plan.label}'
                : s.connectingStatus(profile.name);
            _uplink = '0 B/s';
            _downlink = '0 B/s';
            _sessionTotal = '0 B';
            _lastConfigSummary = configSummary;
          });
        }

        bool started;
        try {
          started = await _nativeCall(
            'startVPN',
            _vpnEngine.startVPN(),
            timeout: _nativeStartTimeout,
          );
        } on Object catch (error) {
          started = false;
          lastStartError = _redactSensitive('$error');
        }
        if (started) {
          final finalStatus = await _waitForVpnStatus({
            AurumVpnStatus.started,
          }, timeout: const Duration(seconds: 14));
          if (finalStatus == AurumVpnStatus.started) {
            if (profile.kind != VpnProfileKind.naive) {
              connected = true;
              break;
            }

            if (await _probeLocalMixedProxy()) {
              connected = true;
              break;
            } else {
              startupProbeDegraded = true;
              connected = true;
              _queueLog(
                'Startup proxy probe did not pass after VPN status Started; '
                'keeping tunnel alive and handing off to watchdog.',
              );
              break;
            }
          } else {
            lastStartError = s.vpnNotConnected(finalStatus);
          }
        } else {
          lastStartError = s.vpnStartFailed;
        }

        if (!connected) {
          _queueLog(
            'VPN start retry [$attempt/${plan.label}]: '
            '${_redactSensitive('$lastStartError')}',
          );
          await _stopVpnCore(updateMessage: false);
          await Future<void>.delayed(const Duration(milliseconds: 1600));
          await _bestEffortNative(
            'saveConfig retry',
            _vpnEngine.saveConfig(config),
            timeout: _nativeConfigTimeout,
          );
          _ignoreStoppedUntil = DateTime.now().add(const Duration(seconds: 14));
        }
      }

      if (!connected && planIndex < plans.length - 1) {
        _queueLog('Naive mode fallback: ${plan.label} did not pass probe.');
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
    }

    if (!connected) {
      throw StateError('${lastStartError ?? s.vpnStartFailed}');
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _store.saveSelectedProfileId(profile.id);
    if (mounted) {
      setState(() {
        _selectedProfileId = profile.id;
        _lastError = null;
        _autoReconnectAttempts = 0;
        _nextAutoReconnectAt = null;
        _tunnelHealthFailures = startupProbeDegraded
            ? _tunnelHealthFailureThreshold - 1
            : 0;
        _autoRecoveryArmed = true;
        _connectedSince ??= DateTime.now();
        _clockNow = DateTime.now();
        _lastTrafficAt = DateTime.now();
        _lastHealthyAt = startupProbeDegraded ? null : DateTime.now();
        _lastSessionTrafficBytes = 0;
        _nextTunnelHealthCheckAt = DateTime.now().add(
          startupProbeDegraded
              ? _startupProbeRecheckDelay
              : _tunnelHealthProbeInterval,
        );
        _message = s.connectionProfile(profile.name);
      });
      unawaited(_syncConnectionNotification());
    }
    unawaited(
      _recordProfileStability(profile, (stats) => stats.recordStartSuccess()),
    );
    unawaited(_refreshConnectedCountry(profile.id));
  }

  String? _profileConnectBlockReason(VpnProfile profile) {
    if (!profile.kind.isClientSupported) {
      return s.unsupportedProtocol(profile.kind);
    }

    return null;
  }

  Future<void> _disconnect() async {
    _autoRecoveryArmed = false;
    await _runBusy(() => _stopVpnCore(), message: s.disconnectingVpn);
  }

  Future<void> _stopVpnCore({bool updateMessage = true}) async {
    _stoppingByUser = true;
    _ignoreStoppedUntil = DateTime.now().add(const Duration(seconds: 18));
    if (mounted) {
      setState(() => _lastError = null);
    }
    try {
      final status = await _refreshVpnStatus();
      if (status != AurumVpnStatus.stopped) {
        await _vpnEngine.stopVPN().timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            _queueLog('Native call timeout [stopVPN]');
            return true;
          },
        );
        final stoppedStatus = await _waitForVpnStatus({
          AurumVpnStatus.stopped,
        }, timeout: const Duration(seconds: 7));
        if (stoppedStatus != AurumVpnStatus.stopped) {
          _queueLog('VPN stop cleanup is still finishing: $stoppedStatus');
        }
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }

      if (mounted) {
        _ignoreStoppedUntil = DateTime.now().add(const Duration(seconds: 18));
        setState(() {
          _status = AurumVpnStatus.stopped;
          _uplink = '0 B/s';
          _downlink = '0 B/s';
          if (updateMessage) {
            _autoRecoveryArmed = false;
            _connectedSince = null;
            _lastTrafficAt = null;
            _lastHealthyAt = null;
            _lastSessionTrafficBytes = 0;
            _tunnelHealthFailures = 0;
          }
          _lastError = null;
          if (updateMessage) {
            _message = s.vpnStopped;
          }
        });
        unawaited(_syncConnectionNotification());
      }
    } finally {
      _stoppingByUser = false;
    }
  }

  Future<String> _refreshVpnStatus() async {
    try {
      final status = await _nativeCall(
        'getVPNStatus',
        _vpnEngine.getVPNStatus(),
        timeout: _nativeShortTimeout,
      );
      if (mounted) {
        setState(() => _status = status);
      }
      return status;
    } on Object {
      return _status;
    }
  }

  Future<String> _waitForVpnStatus(
    Set<String> expected, {
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    var latest = _status;
    while (DateTime.now().isBefore(deadline)) {
      latest = await _refreshVpnStatus();
      if (expected.contains(latest)) {
        return latest;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return latest;
  }

  Future<void> _refreshStatusWatchdog() async {
    if (!mounted || _busy || _statusWatchdogInFlight) {
      return;
    }

    _statusWatchdogInFlight = true;
    try {
      final previous = _status;
      final status = await _refreshVpnStatus();
      final ignoreStopped =
          _ignoreStoppedUntil != null &&
          DateTime.now().isBefore(_ignoreStoppedUntil!);
      if (previous == AurumVpnStatus.started &&
          status == AurumVpnStatus.stopped &&
          _autoRecoveryArmed &&
          !_stoppingByUser &&
          !ignoreStopped &&
          mounted) {
        _markUnexpectedStop('watchdog');
      } else if (status == AurumVpnStatus.started &&
          _autoRecoveryArmed &&
          !_stoppingByUser &&
          !ignoreStopped) {
        final now = DateTime.now();
        final stale = _isTunnelStale(now);
        if (stale) {
          _nextTunnelHealthCheckAt = now;
          _setKeeperAction('watchdog-stale-check');
          _queueLog('VPN watchdog: stale tunnel check forced.');
        }
        await _refreshTunnelHealth(
          source: stale ? 'watchdog-stale' : 'watchdog',
        );
      }
    } finally {
      _statusWatchdogInFlight = false;
    }
  }

  void _markUnexpectedStop(String source) {
    if (!mounted || _stoppingByUser || !_autoRecoveryArmed) {
      return;
    }

    final profile = _selectedProfile;
    _queueLog('VPN watchdog: unexpected stop detected from $source.');
    if (profile != null) {
      unawaited(
        _recordProfileStability(
          profile,
          (stats) => stats.recordStartFailure('unexpected-stop:$source'),
        ),
      );
    }
    setState(() {
      _lastError = s.vpnStoppedUnexpectedly;
      _message = profile == null
          ? s.openLogsMessage
          : '${s.vpnStoppedUnexpectedly}. ${s.connectingStatus(profile.name)}';
    });
    unawaited(_recoverUnexpectedStop(source));
  }

  Future<void> _refreshTunnelHealth({String source = 'watchdog'}) async {
    if (_autoReconnectInFlight || _tunnelHealthCheckInFlight || !mounted) {
      return;
    }

    final profile = _selectedProfile;
    if (profile == null) {
      return;
    }

    final now = DateTime.now();
    final nextCheckAt = _nextTunnelHealthCheckAt;
    if (nextCheckAt != null && now.isBefore(nextCheckAt)) {
      return;
    }

    final lastTrafficAt = _lastTrafficAt;
    if (lastTrafficAt != null &&
        now.difference(lastTrafficAt) < _recentTrafficGrace) {
      _tunnelHealthFailures = 0;
      _lastHealthyAt = lastTrafficAt;
      _setKeeperAction('traffic-ok:$source', at: lastTrafficAt);
      _nextTunnelHealthCheckAt = now.add(_tunnelHealthProbeInterval);
      unawaited(
        _recordProfileStability(
          profile,
          (stats) => stats.recordHealthy(at: lastTrafficAt),
        ),
      );
      return;
    }

    _nextTunnelHealthCheckAt = now.add(_tunnelHealthProbeInterval);
    _tunnelHealthCheckInFlight = true;
    try {
      final healthy = await _probeLocalMixedProxy(
        attempts: _healthProbeAttemptsFor(source),
        logFailures: false,
      );
      if (!mounted || _status != AurumVpnStatus.started) {
        return;
      }

      if (healthy) {
        _tunnelHealthFailures = 0;
        _lastHealthyAt = DateTime.now();
        _setKeeperAction('probe-ok:$source', at: _lastHealthyAt);
        unawaited(
          _recordProfileStability(profile, (stats) => stats.recordHealthy()),
        );
        return;
      }

      _tunnelHealthFailures += 1;
      _setKeeperAction('probe-failed:$source');
      unawaited(
        _recordProfileStability(
          profile,
          (stats) => stats.recordHealthFailure('health-probe:$source'),
        ),
      );
      _queueLog(
        'VPN watchdog: health probe failed #$_tunnelHealthFailures from $source '
        'for ${profile.name}.',
      );

      if (_tunnelHealthFailures >= _tunnelHealthFailureThreshold) {
        _tunnelHealthFailures = 0;
        _queueLog(
          'VPN watchdog: tunnel is unhealthy, reconnecting ${profile.name}.',
        );
        if (mounted) {
          setState(() {
            _lastError = null;
            _message = s.connectingStatus(profile.name);
          });
        }
        _setKeeperAction('reconnect:health-probe');
        unawaited(_recoverConnection('health-probe', forceRestart: true));
      }
    } finally {
      _tunnelHealthCheckInFlight = false;
    }
  }

  Future<void> _recoverUnexpectedStop(String source) {
    return _recoverConnection(source, forceRestart: false);
  }

  Future<void> _recoverConnection(
    String source, {
    required bool forceRestart,
  }) async {
    if (_autoReconnectInFlight || _busy || _stoppingByUser || !mounted) {
      return;
    }

    final profile = _selectedProfile;
    if (profile == null) {
      return;
    }

    final now = DateTime.now();
    final nextAttemptAt = _nextAutoReconnectAt;
    if (nextAttemptAt != null && now.isBefore(nextAttemptAt)) {
      return;
    }

    if (_autoReconnectAttempts >= _autoReconnectMaxAttempts) {
      _nextAutoReconnectAt = now.add(const Duration(minutes: 5));
      _autoReconnectAttempts = 0;
      _queueLog(
        'VPN watchdog: auto reconnect paused for mobile network cooldown; '
        'attempt counter reset for the next recovery window.',
      );
      if (mounted) {
        setState(() {
          _message = s.networkRecoveryPaused(profile.name);
        });
      }
      return;
    }

    _autoReconnectInFlight = true;
    _autoReconnectAttempts += 1;
    if (mounted) {
      setState(() => _busy = true);
    }
    final attempt = _autoReconnectAttempts;
    final delay = attempt == 1
        ? const Duration(milliseconds: 900)
        : attempt == 2
        ? const Duration(seconds: 4)
        : attempt == 3
        ? const Duration(seconds: 10)
        : const Duration(seconds: 20);
    final cooldown = attempt <= 2
        ? const Duration(seconds: 25)
        : attempt <= 4
        ? const Duration(seconds: 60)
        : const Duration(seconds: 120);
    _nextAutoReconnectAt = now.add(cooldown);

    _queueLog(
      'VPN watchdog: auto reconnect #$attempt from $source for ${profile.name}.',
    );
    _setKeeperAction('reconnect-attempt:$source#$attempt');

    try {
      await Future<void>.delayed(delay);
      if (!mounted || _stoppingByUser) {
        return;
      }

      final status = await _refreshVpnStatus();
      if (!forceRestart && status != AurumVpnStatus.stopped) {
        _autoReconnectAttempts = 0;
        _nextAutoReconnectAt = null;
        _setKeeperAction('reconnect-skip:$source#$attempt');
        return;
      }

      if (mounted) {
        setState(() {
          _lastError = null;
          _message = s.connectingStatus(profile.name);
        });
      }

      if (forceRestart && status != AurumVpnStatus.stopped) {
        await _stopVpnCore(updateMessage: false);
        await Future<void>.delayed(const Duration(milliseconds: 1200));
      }

      await _startVpnCore(profile);
      _setKeeperAction('reconnect-ok:$source#$attempt');
      unawaited(
        _recordProfileStability(profile, (stats) => stats.recordRecovery()),
      );
    } on Object catch (error) {
      final errorText = _redactSensitive('$error');
      _queueLog('VPN watchdog reconnect failed: $errorText');
      _setKeeperAction('reconnect-error:$source#$attempt');
      unawaited(
        _recordProfileStability(
          profile,
          (stats) => stats.recordStartFailure(errorText),
        ),
      );
      if (mounted) {
        setState(() {
          _lastError = errorText;
          _message = errorText;
        });
      }
    } finally {
      _autoReconnectInFlight = false;
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  List<_ConnectionConfigPlan> _connectionPlans(VpnProfile profile) {
    if (profile.kind != VpnProfileKind.naive) {
      return const [_ConnectionConfigPlan(NaiveOutboundMode.auto, 'auto')];
    }

    final outboundType = (profile.outbound?['type'] as String?)?.toLowerCase();
    if (outboundType == 'http') {
      return const [
        _ConnectionConfigPlan(NaiveOutboundMode.httpConnect, 'https-connect'),
        _ConnectionConfigPlan(NaiveOutboundMode.native, 'native-naive'),
      ];
    }

    return const [
      _ConnectionConfigPlan(NaiveOutboundMode.httpConnect, 'https-connect'),
      _ConnectionConfigPlan(NaiveOutboundMode.native, 'native-naive'),
    ];
  }

  Future<bool> _probeLocalMixedProxy({
    int attempts = 2,
    bool logFailures = true,
  }) async {
    final endpoints = <({Uri uri, bool allowCertificateMismatch})>[
      (
        uri: Uri.https('cp.cloudflare.com', '/generate_204'),
        allowCertificateMismatch: false,
      ),
      (
        uri: Uri.https('www.gstatic.com', '/generate_204'),
        allowCertificateMismatch: false,
      ),
      // Some Naive servers have broken resolver settings but still proxy IP
      // targets correctly. This probe keeps startup from rejecting such
      // profiles while server-side DNS is being repaired.
      (uri: Uri.https('1.1.1.1', '/'), allowCertificateMismatch: true),
    ];

    for (var attempt = 1; attempt <= attempts; attempt += 1) {
      for (final endpoint in endpoints) {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5)
          ..badCertificateCallback = endpoint.allowCertificateMismatch
              ? (_, host, _) => host == endpoint.uri.host
              : null
          ..findProxy = (_) =>
              'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}';
        try {
          final request = await client
              .getUrl(endpoint.uri)
              .timeout(const Duration(seconds: 5));
          request.headers.set(
            HttpHeaders.userAgentHeader,
            'YurichConnect/$_appVersion',
          );
          request.followRedirects = false;
          final response = await request.close().timeout(
            const Duration(seconds: 7),
          );
          await response.drain<void>().timeout(
            const Duration(seconds: 3),
            onTimeout: () {},
          );
          if (response.statusCode >= 200 && response.statusCode < 400) {
            return true;
          }
          if (logFailures) {
            _queueLog(
              'VPN health probe HTTP ${response.statusCode}: ${endpoint.uri}',
            );
          }
        } on Object catch (error) {
          if (logFailures) {
            _queueLog('VPN health probe failed: ${_redactSensitive('$error')}');
          }
        } finally {
          client.close(force: true);
        }
      }

      if (attempt < attempts) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }

    return false;
  }

  Future<void> _pingProfiles(List<VpnProfile> profiles) async {
    if (_pingAllInFlight || profiles.isEmpty) {
      return;
    }

    _pingAllInFlight = true;
    try {
      for (final profile in profiles.take(16)) {
        if (!mounted) {
          return;
        }
        await _pingProfile(profile);
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    } finally {
      _pingAllInFlight = false;
    }
  }

  Future<void> _pingProfile(VpnProfile profile) async {
    final server = profile.server?.trim();
    final port = profile.port ?? 443;
    if (server == null || server.isEmpty || port <= 0) {
      return;
    }
    if (_profilePingBusy[profile.id] == true) {
      return;
    }

    if (mounted) {
      setState(() {
        _profilePingBusy[profile.id] = true;
        _profilePingError.remove(profile.id);
      });
    }

    final stopwatch = Stopwatch()..start();
    Socket? socket;
    try {
      if (_usesUdpEndpoint(profile)) {
        final addresses = await InternetAddress.lookup(
          server,
        ).timeout(const Duration(seconds: 4));
        if (addresses.isEmpty) {
          throw const SocketException('DNS lookup returned no addresses');
        }
        stopwatch.stop();
        if (!mounted) {
          return;
        }
        setState(() {
          _profilePingMs.remove(profile.id);
          _profilePingText[profile.id] = stopwatch.elapsedMilliseconds <= 1
              ? 'UDP ok'
              : 'DNS ${stopwatch.elapsedMilliseconds} ms';
          _profilePingError.remove(profile.id);
        });
        if (profile.id == _selectedProfileId) {
          unawaited(_syncConnectionNotification());
        }
        return;
      }

      socket = await Socket.connect(
        server,
        port,
        timeout: const Duration(seconds: 4),
      );
      stopwatch.stop();
      if (!mounted) {
        return;
      }
      setState(() {
        _profilePingMs[profile.id] = stopwatch.elapsedMilliseconds;
        _profilePingText.remove(profile.id);
        _profilePingError.remove(profile.id);
      });
      if (profile.id == _selectedProfileId) {
        unawaited(_syncConnectionNotification());
      }
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _profilePingMs.remove(profile.id);
        _profilePingText.remove(profile.id);
        _profilePingError[profile.id] = _redactSensitive('$error');
      });
    } finally {
      socket?.destroy();
      if (mounted) {
        setState(() => _profilePingBusy[profile.id] = false);
      }
    }
  }

  String _profilePingLabel(VpnProfile profile) {
    if (_profilePingBusy[profile.id] == true) {
      return '...';
    }
    final text = _profilePingText[profile.id];
    if (text != null) {
      return text;
    }
    final ms = _profilePingMs[profile.id];
    if (ms != null) {
      return '$ms ms';
    }
    if (_profilePingError.containsKey(profile.id)) {
      return 'offline';
    }
    return 'ping';
  }

  bool _usesUdpEndpoint(VpnProfile profile) {
    if (profile.kind == VpnProfileKind.hysteria ||
        profile.kind == VpnProfileKind.hysteria2) {
      return true;
    }

    final outbound = profile.outbound;
    if (outbound == null) {
      return false;
    }
    final type = outbound['type']?.toString().toLowerCase();
    return type == 'hysteria' || type == 'hysteria2' || type == 'hy2';
  }

  Future<void> _resolveProfileCountries(List<VpnProfile> profiles) async {
    if (_countryResolveInFlight || profiles.isEmpty) {
      return;
    }

    _countryResolveInFlight = true;
    try {
      for (final profile in profiles.take(48)) {
        if (!mounted) {
          return;
        }
        if (_leadingFlag(profile.name) != null ||
            (profile.countryCode ?? '').trim().isNotEmpty) {
          continue;
        }

        final geo = await _geoService.resolveEndpointCountry(profile);
        if (geo != null) {
          await _saveProfileCountry(profile.id, geo);
        }
        await Future<void>.delayed(const Duration(milliseconds: 180));
      }
    } finally {
      _countryResolveInFlight = false;
    }
  }

  Future<void> _refreshConnectedCountry(String profileId) async {
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (!mounted || _status != AurumVpnStatus.started) {
      return;
    }

    final geo = await _geoService.resolveExitCountryThroughTunnel();
    if (geo != null) {
      await _saveProfileCountry(profileId, geo);
      _queueLog(
        'Geo: exit country ${geo.countryCode}'
        '${geo.ip == null ? '' : ' via ${geo.ip}'}',
      );
    }
  }

  Future<void> _saveProfileCountry(String profileId, ProfileGeo geo) async {
    final index = _profiles.indexWhere((profile) => profile.id == profileId);
    if (index < 0) {
      return;
    }

    final current = _profiles[index];
    if (current.countryCode == geo.countryCode &&
        current.countryName == geo.countryName) {
      return;
    }

    final next = [..._profiles];
    next[index] = current.copyWith(
      countryCode: geo.countryCode,
      countryName: geo.countryName,
    );
    await _store.saveProfiles(next);
    if (!mounted) {
      return;
    }
    setState(() => _profiles = next);
    if (profileId == _selectedProfileId) {
      unawaited(_syncConnectionNotification());
    }
  }

  String? _profileCountryFlag(VpnProfile profile) {
    final existing = _leadingFlag(profile.name);
    if (existing != null) {
      return existing;
    }

    final cached = ProfileGeo.countryCodeToFlag(profile.countryCode);
    if (cached != null) {
      return cached;
    }

    final haystack = '${profile.name} ${profile.server ?? ''}'.toLowerCase();
    if (haystack.contains('росси') ||
        haystack.contains('russia') ||
        haystack.endsWith('.ru') ||
        haystack.endsWith('.su') ||
        haystack.endsWith('.рф')) {
      return '🇷🇺';
    }
    if (haystack.contains('фин') ||
        haystack.contains('finland') ||
        haystack.endsWith('.fi')) {
      return '🇫🇮';
    }
    if (haystack.contains('герман') ||
        haystack.contains('germany') ||
        haystack.endsWith('.de')) {
      return '🇩🇪';
    }
    if (haystack.contains('сша') ||
        haystack.contains('usa') ||
        haystack.contains('america') ||
        haystack.endsWith('.us')) {
      return '🇺🇸';
    }
    if (haystack.contains('japan') || haystack.contains('япон')) {
      return '🇯🇵';
    }
    if (haystack.contains('netherlands') || haystack.contains('нидер')) {
      return '🇳🇱';
    }
    if (haystack.contains('france') || haystack.contains('франц')) {
      return '🇫🇷';
    }
    if (haystack.contains('canada') || haystack.contains('канада')) {
      return '🇨🇦';
    }
    if (haystack.contains('turkey') || haystack.contains('турц')) {
      return '🇹🇷';
    }
    if (haystack.contains('uk') ||
        haystack.contains('united kingdom') ||
        haystack.endsWith('.co.uk')) {
      return '🇬🇧';
    }
    return '🌐';
  }

  String _profileDisplayName(VpnProfile profile) {
    final trimmed = profile.name.trimLeft();
    if (_leadingFlag(trimmed) != null) {
      return String.fromCharCodes(trimmed.runes.skip(2)).trimLeft();
    }
    return profile.name;
  }

  String? _leadingFlag(String value) {
    final runes = value.trimLeft().runes.take(2).toList(growable: false);
    if (runes.length < 2) {
      return null;
    }
    final isFlag = runes.every((rune) => rune >= 0x1F1E6 && rune <= 0x1F1FF);
    return isFlag ? String.fromCharCodes(runes) : null;
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) {
      return '00:00';
    }
    final formatted = TrafficFormatter.formatDuration(duration);
    return formatted.startsWith('00:') ? formatted.substring(3) : formatted;
  }

  Future<void> _setLanguage(_AppLanguage language) async {
    if (_language == language) {
      return;
    }
    await _store.saveLanguageCode(language.code);
    if (!mounted) {
      return;
    }
    final strings = _Strings.forLanguage(language);
    setState(() {
      _language = language;
      _message = strings.languageChanged;
    });
    try {
      await _vpnEngine
          .setNotificationDescription(strings.notificationDescription)
          .timeout(_nativeShortTimeout);
    } on Object {
      // Native plugin is unavailable in widget tests and desktop preview.
    }
  }

  Future<void> _setSmartRouteRuDirect(bool enabled) async {
    if (_smartRouteRuDirect == enabled || _busy) {
      return;
    }

    final profile = _selectedProfile;
    final shouldRestart = _connected && profile != null;
    await _store.saveSmartRouteRuDirect(enabled);
    if (!mounted) {
      return;
    }

    setState(() {
      _smartRouteRuDirect = enabled;
      _message = enabled ? s.smartRouteEnabled : s.smartRouteDisabled;
    });

    if (!shouldRestart) {
      return;
    }

    await _runBusy(() async {
      await _stopVpnCore(updateMessage: false);
      await _startVpnCore(profile);
    }, message: s.smartRouteApplying);
  }

  Future<List<String>> _smartRouteBypassPackages() async {
    if (!_smartRouteRuDirect) {
      return const [];
    }
    return _installedAppsService.installedPackageNames();
  }

  String _profileKindLabel(VpnProfileKind kind) {
    return ProtocolDisplayMapper.mapProtocolToDisplayName(
      switch (kind) {
        VpnProfileKind.vlessReality ||
        VpnProfileKind.vlessTls ||
        VpnProfileKind.vlessXhttp ||
        VpnProfileKind.vlessMkcp => 'vless',
        VpnProfileKind.naive => 'naive',
        VpnProfileKind.hysteria2 => 'hysteria2',
        VpnProfileKind.hysteria => 'hysteria',
        VpnProfileKind.singBoxConfig => 'Sing-box',
      },
      transport: switch (kind) {
        VpnProfileKind.vlessXhttp => 'xhttp',
        VpnProfileKind.vlessMkcp => 'mkcp',
        _ => 'tcp',
      },
      security: switch (kind) {
        VpnProfileKind.vlessReality ||
        VpnProfileKind.vlessXhttp ||
        VpnProfileKind.vlessMkcp => 'reality',
        _ => null,
      },
    );
  }

  Future<void> _deleteProfile(VpnProfile profile) async {
    if (_busy) {
      return;
    }

    await _runBusy(() async {
      final wasSelected = _selectedProfileId == profile.id;
      if (wasSelected && _connected) {
        _autoRecoveryArmed = false;
        await _stopVpnCore(updateMessage: true);
      }

      final next = _profiles
          .where((item) => item.id != profile.id)
          .toList(growable: false);
      final nextSelectedId = wasSelected
          ? (next.isEmpty ? null : next.first.id)
          : _selectedProfileId;

      await _store.rememberDeletedSubscriptionProfile(profile);
      await _store.saveProfiles(next);
      await _store.saveSelectedProfileId(nextSelectedId);
      if (!mounted) {
        return;
      }
      setState(() {
        _profiles = next;
        _selectedProfileId = nextSelectedId;
        _profilePingMs.remove(profile.id);
        _profilePingBusy.remove(profile.id);
        _profilePingError.remove(profile.id);
        if (next.isEmpty ||
            !next.any((item) => _profileMatchesTab(item, _profileTab))) {
          _profileTab = _ProfileTab.all;
        }
        _message = s.profileDeleted;
      });
    }, message: s.working);
  }

  Future<void> _copySelected() async {
    final selected = _selectedProfile;
    if (selected == null) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: selected.originalInput));
    _showSnack(s.linkCopied);
  }

  Future<void> _showQr() async {
    final selected = _selectedProfile;
    if (selected == null || selected.originalInput.trim().isEmpty) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(selected.name),
          content: SizedBox(
            width: 260,
            child: QrImageView(
              data: selected.originalInput,
              version: QrVersions.auto,
              backgroundColor: Colors.white,
              size: 240,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(s.close),
            ),
          ],
        );
      },
    );
  }

  Future<T> _nativeCall<T>(
    String label,
    Future<T> future, {
    required Duration timeout,
  }) async {
    try {
      return await future.timeout(timeout);
    } on TimeoutException {
      final message = 'Native call timeout [$label]';
      _queueLog(message);
      throw TimeoutException(message, timeout);
    }
  }

  int _eventInt(Object? value) {
    return switch (value) {
      int() => value,
      num() => value.round(),
      String() => int.tryParse(value) ?? 0,
      _ => 0,
    };
  }

  Future<void> _bestEffortNative<T>(
    String label,
    Future<T> future, {
    Duration timeout = _nativeShortTimeout,
  }) async {
    try {
      await _nativeCall(label, future, timeout: timeout);
    } on Object catch (error) {
      _queueLog('Native call ignored [$label]: ${_redactSensitive('$error')}');
    }
  }

  Future<void> _runBusy(
    Future<void> Function() action, {
    String? message,
  }) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _message = message ?? s.working;
    });
    try {
      await action();
    } on Object catch (error) {
      final errorText = _redactSensitive('$error');
      if (mounted) {
        setState(() {
          _lastError = errorText;
          _message = errorText;
        });
        _showSnack(
          errorText,
          action: SnackBarAction(
            label: s.report,
            onPressed: () => unawaited(_emailDeveloper()),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _showSnack(String text, {SnackBarAction? action}) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text), action: action));
  }

  Future<void> _openUrl(String value) async {
    final uri = Uri.parse(value);
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      _showSnack(s.cannotOpenLink);
    }
  }

  Future<void> _checkAndInstallUpdate() async {
    if (_updateBusy) {
      return;
    }

    setState(() {
      _updateBusy = true;
      _updateProgress = null;
      _updateMessage = s.updateChecking;
    });

    try {
      final abis = await _updateService.supportedAbis();
      final update = await _updateService.findLatest(
        currentVersion: _appVersion,
        supportedAbis: abis,
      );
      if (update == null) {
        if (mounted) {
          setState(() {
            _availableUpdate = null;
            _updateMessage = s.updateNoUpdates(_appVersion);
          });
        }
        return;
      }

      if (mounted) {
        setState(() {
          _availableUpdate = update;
          _updateMessage = s.updateDownloading(update.version);
        });
      }

      final file = await _updateService.download(
        update,
        onProgress: (progress) {
          if (!mounted) {
            return;
          }
          setState(() {
            _updateProgress = progress;
            _updateMessage = progress == null
                ? s.updateDownloading(update.version)
                : s.updateDownloadingProgress(
                    update.version,
                    (progress * 100).round().clamp(0, 100),
                  );
          });
        },
      );

      if (mounted) {
        setState(() => _updateMessage = s.updateInstalling(update.version));
      }
      await _updateService.installApk(file);
      if (mounted) {
        setState(() => _updateMessage = s.updateInstallerOpened);
      }
    } on AppUpdatePermissionException {
      if (mounted) {
        setState(() => _updateMessage = s.updateInstallPermission);
        _showSnack(
          s.updateInstallPermission,
          action: SnackBarAction(
            label: s.openSettings,
            onPressed: () => unawaited(_updateService.openInstallSettings()),
          ),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        final errorText = _redactSensitive('$error');
        setState(() => _updateMessage = s.updateFailed(errorText));
        _showSnack(
          s.updateFailed(errorText),
          action: SnackBarAction(
            label: s.downloadApk,
            onPressed: () => unawaited(
              _openUrl(AppUpdateService.latestApkDownloadUri.toString()),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _updateBusy = false);
      }
    }
  }

  Future<void> _checkLatestUpdateNotice() async {
    if (_updateBusy) {
      return;
    }

    try {
      final abis = await _updateService.supportedAbis().timeout(
        const Duration(seconds: 4),
        onTimeout: () => const <String>[],
      );
      final update = await _updateService
          .findLatest(currentVersion: _appVersion, supportedAbis: abis)
          .timeout(const Duration(seconds: 26));
      if (!mounted) {
        return;
      }

      if (update == null) {
        if (_availableUpdate != null) {
          setState(() => _availableUpdate = null);
        }
        return;
      }

      setState(() {
        _availableUpdate = update;
        _updateMessage = s.updateAvailable(update.version);
      });

      if (_updateNoticeShown) {
        return;
      }
      _updateNoticeShown = true;
      _showSnack(
        s.updateAvailableSnack(update.version),
        action: SnackBarAction(
          label: s.updateNow,
          onPressed: () => unawaited(_checkAndInstallUpdate()),
        ),
      );
      await _bestEffortNative(
        'showUpdateNotification',
        _vpnEngine
            .showAppNotification(
              title: s.updateAvailableTitle,
              body: s.updateAvailableBody(update.version),
              id: 7045,
            )
            .timeout(_nativeShortTimeout, onTimeout: () => false),
      );
    } on Object catch (error) {
      _queueLog('Update notice check skipped: ${_redactSensitive('$error')}');
    }
  }

  Future<void> _emailDeveloper() async {
    await _loadBufferedLogs();
    final report = _buildDiagnosticReport();
    final uri = Uri.parse(
      'mailto:$_supportEmail?subject=${Uri.encodeComponent(s.mailSubject)}&body=${Uri.encodeComponent(report)}',
    );
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      await Clipboard.setData(ClipboardData(text: report));
      _showSnack(s.mailFallback);
    }
  }

  String _buildDiagnosticReport() {
    final profile = _selectedProfile;
    final now = DateTime.now();
    final lines = <String>[
      '$_appName diagnostic',
      'app_version: $_appVersion',
      if (_appBuildNumber.isNotEmpty) 'app_build: $_appBuildNumber',
      'generated_local: ${now.toIso8601String()}',
      'generated_utc: ${now.toUtc().toIso8601String()}',
      'platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'locale: ${Platform.localeName}',
      'config_target: ${_vpnEngine.configTarget.name}',
      if (_lastConfigSummary != null) 'config: $_lastConfigSummary',
      'smart_route_enabled: $_smartRouteRuDirect',
      if (_smartRouteRuDirect) ...[
        'smart_route_mode: ru-apps-direct/global-vpn',
        'smart_route_global_packages: ${SmartRouteRules.globalProxyPackageNames.length}',
        'smart_route_ru_packages_builtin: ${SmartRouteRules.ruDirectPackageNames.length}',
        'smart_route_global_domains: ${SmartRouteRules.globalProxyDomains.length + SmartRouteRules.globalProxyDomainSuffixes.length}',
      ],
      'battery_optimization_ignored: $_batteryOptimizationIgnored',
      'status: $_status',
      'connection_degraded: $_connectionDegraded',
      'message: ${_redactSensitive(_message)}',
      if (_lastError != null) 'last_error: $_lastError',
      'uptime: ${_formatDuration(_connectedDuration)}',
      'auto_recovery_armed: $_autoRecoveryArmed',
      'auto_reconnect_attempts: $_autoReconnectAttempts',
      'health_failures: $_tunnelHealthFailures',
      if (_lastKeeperAction != null) 'keeper_last_action: $_lastKeeperAction',
      if (_lastKeeperActionAt != null)
        'keeper_last_action_local: ${_lastKeeperActionAt!.toIso8601String()}',
      if (_nextTunnelHealthCheckAt != null)
        'next_health_check_local: ${_nextTunnelHealthCheckAt!.toIso8601String()}',
      if (_nextAutoReconnectAt != null)
        'next_reconnect_local: ${_nextAutoReconnectAt!.toIso8601String()}',
      if (_lastTrafficAt != null)
        'last_traffic_local: ${_lastTrafficAt!.toIso8601String()}',
      if (_lastHealthyAt != null)
        'last_healthy_local: ${_lastHealthyAt!.toIso8601String()}',
      if (profile != null) ...[
        'profile: ${_redactSensitive(profile.name)}',
        'protocol: ${_profileKindLabel(profile.kind)}',
        'endpoint: ${_redactSensitive(profile.endpoint)}',
        'country: ${_profileCountryFlag(profile) ?? 'unknown'}'
            '${profile.countryCode == null ? '' : ' ${profile.countryCode}'}'
            '${profile.countryName == null ? '' : ' ${profile.countryName}'}',
        'profile_ping: ${_profilePingLabel(profile)}',
        'profile_stability: ${_profileStabilityLabel(profile)}',
        'profile_stability_penalty: '
            '${_profileStabilityFor(profile.id).autoSelectPenalty()}',
        'profile_successful_starts: '
            '${_profileStabilityFor(profile.id).successfulStarts}',
        'profile_failed_starts: '
            '${_profileStabilityFor(profile.id).failedStarts}',
        'profile_recoveries: ${_profileStabilityFor(profile.id).recoveries}',
        'profile_health_failures: '
            '${_profileStabilityFor(profile.id).healthFailures}',
        if (_profileStabilityFor(profile.id).lastFailureReason != null)
          'profile_last_failure: ${_redactSensitive(_profileStabilityFor(profile.id).lastFailureReason!)}',
      ],
      'traffic: up=$_uplink down=$_downlink total=$_sessionTotal',
      '',
      'profiles:',
      if (_profiles.isEmpty)
        'none'
      else
        ..._profiles.map((item) {
          final expires = item.subscriptionExpiresAt?.toUtc().toIso8601String();
          return [
            '- ${_redactSensitive(item.name)}',
            _profileKindLabel(item.kind),
            _redactSensitive(item.endpoint),
            'country=${_profileCountryFlag(item) ?? 'unknown'}'
                '${item.countryCode == null ? '' : ' ${item.countryCode}'}',
            'ping=${_profilePingLabel(item)}',
            'stability=${_profileStabilityLabel(item)}',
            if (expires != null) 'expires=$expires',
          ].join(' | ');
        }),
      '',
      'logs:',
    ];

    final safeLogs = [..._logs, ..._pendingLogs]
        .toList()
        .reversed
        .take(120)
        .toList()
        .reversed
        .where((log) => !_isDiagnosticNoise(log))
        .map(_redactSensitive);
    lines.addAll(safeLogs.isEmpty ? const ['Логов пока нет.'] : safeLogs);
    return lines.join('\n');
  }

  String _summarizeSingBoxConfig(
    String config, {
    required SingBoxConfigTarget target,
  }) {
    try {
      final decoded = jsonDecode(config);
      if (decoded is! Map) {
        return 'target=${target.name}; raw/custom config';
      }
      final map = decoded.cast<String, dynamic>();
      final inbounds = ((map['inbounds'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
      final tun = inbounds.firstWhere(
        (inbound) => inbound['type'] == 'tun',
        orElse: () => const <String, dynamic>{},
      );
      final excludedPackages = ((tun['exclude_package'] as List?) ?? const [])
          .whereType<String>()
          .toList();
      final hasMixedProxy = inbounds.any(
        (inbound) =>
            inbound['type'] == 'mixed' &&
            inbound['listen'] == '127.0.0.1' &&
            inbound['listen_port'] == SingBoxConfigBuilder.localMixedProxyPort,
      );
      final route = (map['route'] as Map?)?.cast<String, dynamic>() ?? const {};
      final routeRules = ((route['rules'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
      final smartRouteEnabled = routeRules.any(
        (rule) =>
            rule['outbound'] == 'direct' &&
            (rule['domain_suffix'] as List?)?.contains('ru') == true,
      );
      final smartRouteProxyRules = routeRules
          .where(
            (rule) =>
                rule['outbound'] == 'proxy' &&
                (rule.containsKey('domain') ||
                    rule.containsKey('domain_suffix')),
          )
          .length;
      final outbounds = ((map['outbounds'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
      final proxy = outbounds.firstWhere(
        (outbound) => outbound['tag'] == 'proxy',
        orElse: () =>
            outbounds.isEmpty ? const <String, dynamic>{} : outbounds.first,
      );
      final dns = (map['dns'] as Map?)?.cast<String, dynamic>() ?? const {};
      final dnsFinal = dns['final'] ?? 'unknown';
      final dnsServers = ((dns['servers'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
      final hasFakeDns = dnsServers.any((server) => server['type'] == 'fakeip');
      final dnsServer = dnsServers.firstWhere(
        (server) => server['tag'] == dnsFinal,
        orElse: () => const <String, dynamic>{},
      );
      return [
        'target=${target.name}',
        'proxy=${proxy['type'] ?? 'unknown'}',
        'dns=$dnsFinal/${dnsServer['type'] ?? 'unknown'}',
        if (hasFakeDns) 'fake_dns=true',
        'mtu=${tun['mtu'] ?? 'unknown'}',
        'strict_route=${tun['strict_route'] ?? 'unknown'}',
        'stack=${tun['stack'] ?? 'unknown'}',
        'smart_route=$smartRouteEnabled',
        if (smartRouteEnabled)
          'ru_bypass_packages=${excludedPackages.where((item) => item != "online.dnsai.ivanvpn").length}',
        if (smartRouteEnabled) 'global_proxy_rules=$smartRouteProxyRules',
        'network=${proxy['network_strategy'] ?? 'default'}',
        if (proxy['type'] == 'http') 'mode=https-connect',
        if (proxy['type'] == 'naive') 'mode=naive-native',
        if (proxy['type'] == 'http' || proxy['type'] == 'naive')
          'health_probe=mixed-proxy',
        if (proxy['type'] == 'naive')
          'transport=${proxy['quic'] == true ? 'h3/quic' : 'h2'}',
        if (proxy['type'] == 'vless')
          'packet=${proxy['packet_encoding'] ?? 'default'}',
        if (proxy['type'] == 'hysteria2' || proxy['type'] == 'hysteria')
          'transport=udp',
        'mixed_proxy=$hasMixedProxy',
      ].join('; ');
    } on Object {
      return 'target=${target.name}; raw/custom config';
    }
  }

  bool _isDiagnosticNoise(String log) {
    return log.contains('router: found package name:') ||
        log.contains('router: found user id:') ||
        log.contains('router: failed to search process: process not found');
  }

  Future<void> _setLogsExpanded(bool expanded) async {
    if (_logsExpanded == expanded) {
      return;
    }
    _logsExpanded = expanded;

    if (!expanded) {
      await _logSubscription?.cancel();
      _logSubscription = null;
      _pendingLogs.clear();
      _logFlushTimer?.cancel();
      _logFlushTimer = null;
      return;
    }

    _startLogStreaming();
    await _loadBufferedLogs();
  }

  void _startLogStreaming() {
    if (_logSubscription != null) {
      return;
    }

    _logSubscription = _vpnEngine.onLogMessage.listen(
      (event) {
        try {
          if (!mounted || !_logsExpanded || event['type'] != 'log') {
            return;
          }
          final message = event['message'] as String?;
          if (message == null || message.isEmpty) {
            return;
          }
          _queueLog(message);
        } on Object catch (error, stackTrace) {
          _handleEngineStreamError('log', error, stackTrace);
        }
      },
      onError: (Object error, StackTrace stackTrace) =>
          _handleEngineStreamError('log', error, stackTrace),
      cancelOnError: false,
    );
  }

  Future<void> _loadBufferedLogs() async {
    try {
      final bufferedLogs = await _vpnEngine.getLogs().timeout(
        const Duration(seconds: 2),
        onTimeout: () => const <String>[],
      );
      final cleaned = bufferedLogs
          .map(_cleanLog)
          .where((log) => log.isNotEmpty)
          .toList()
          .reversed
          .take(60)
          .toList()
          .reversed
          .toList();
      if (mounted && cleaned.isNotEmpty) {
        setState(() {
          _logs
            ..clear()
            ..addAll(cleaned);
        });
      }
    } on Object {
      // Logs are optional and should never slow down VPN startup.
    }
  }

  String _redactSensitive(String value) {
    return value
        .replaceAllMapped(
          RegExp(r'(naive\+https://)[^:@\s]+:[^@\s]+@', caseSensitive: false),
          (match) => '${match[1]}***:***@',
        )
        .replaceAllMapped(
          RegExp(r'(vless://)[^@\s]+@', caseSensitive: false),
          (match) => '${match[1]}***@',
        )
        .replaceAllMapped(
          RegExp(
            r'((?:hy2|hysteria2|hysteria)://)[^@\s]+@',
            caseSensitive: false,
          ),
          (match) => '${match[1]}***@',
        )
        .replaceAllMapped(
          RegExp(r'(https?://)[^:@/\s]+:[^@/\s]+@', caseSensitive: false),
          (match) => '${match[1]}***:***@',
        )
        .replaceAllMapped(
          RegExp(
            r'("(?:password|uuid|public_key|short_id|auth|auth_str)"\s*:\s*")[^"]+',
            caseSensitive: false,
          ),
          (match) => '${match[1]}***',
        );
  }

  void _queueLog(String message) {
    final cleaned = _cleanLog(message);
    if (cleaned.isEmpty) {
      return;
    }

    _pendingLogs.add(cleaned);
    if (_pendingLogs.length > _maxPendingLogs) {
      _pendingLogs.removeRange(0, _pendingLogs.length - _maxPendingLogs);
    }

    _logFlushTimer ??= Timer(const Duration(milliseconds: 250), () {
      try {
        _logFlushTimer = null;
        if (!mounted || _pendingLogs.isEmpty) {
          return;
        }

        setState(() {
          _logs.addAll(_pendingLogs);
          _pendingLogs.clear();
          if (_logs.length > _maxStoredLogs) {
            _logs.removeRange(0, _logs.length - _maxStoredLogs);
          }
        });
      } on Object catch (error, stackTrace) {
        _handleEngineStreamError('log-flush', error, stackTrace);
      }
    });
  }

  String _cleanLog(String message) {
    return message.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '').trim();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedProfile;
    final connectCandidate = _connected
        ? selected
        : (_autoConnectProfile() ?? selected);
    final selectedProfileId = _connected
        ? (_selectedProfileId ?? selected?.id)
        : (connectCandidate?.id ?? _selectedProfileId ?? selected?.id);
    final activeProfileId = _connected ? selectedProfileId : null;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        flexibleSpace: const _AppBarGradient(),
        title: const Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(8)),
              child: Image(
                image: AssetImage('assets/images/app_icon.png'),
                width: 36,
                height: 36,
                fit: BoxFit.cover,
              ),
            ),
            SizedBox(width: 10),
            Text(_appName),
          ],
        ),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: YurichGradients.background),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: _StatusPanel(
                  pulse: _glowPulse,
                  strings: s,
                  status: _status,
                  connectionState: _connectionUiState,
                  degraded: _connectionDegraded,
                  message: _message,
                  uplink: _uplink,
                  downlink: _downlink,
                  uptime: _formatDuration(_connectedDuration),
                  total: _sessionTotal,
                  onToggle: _toggleVpn,
                  toggleEnabled: !_busy && _profiles.isNotEmpty,
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  children: [
                    _ProfilePanel(
                      pulse: _glowPulse,
                      strings: s,
                      profiles: _profiles,
                      selectedProfile: connectCandidate,
                      selectedId: selectedProfileId,
                      activeProfileId: activeProfileId,
                      selectedTab: _profileTab,
                      profilesExpanded: _profilesExpanded,
                      onTabChanged: (tab) => setState(() {
                        _profileTab = tab;
                        _profilesExpanded = false;
                      }),
                      onProfilesExpandedChanged: (expanded) =>
                          setState(() => _profilesExpanded = expanded),
                      onSelect: _selectProfile,
                      onAdd: _showImportSheet,
                      onCopy: selected == null ? null : _copySelected,
                      onQr: selected == null ? null : _showQr,
                      onDeleteProfile: (profile) =>
                          unawaited(_deleteProfile(profile)),
                      onRefreshSubscriptions: () =>
                          unawaited(_refreshSubscriptions()),
                      hasSubscriptionSources: _profiles.isNotEmpty,
                      subscriptionRefreshBusy: _subscriptionRefreshBusy,
                      subscriptionStatus: _subscriptionTileStatus,
                      subscriptionNeedsAttention: _subscriptionNeedsAttention,
                      batteryOptimizationIgnored: _batteryOptimizationIgnored,
                      smartRouteRuDirect: _smartRouteRuDirect,
                      keeperStatus: _keeperStatusLabel,
                      lastHealthStatus: _lastHealthStatusLabel,
                      autoRecoveryStatus: _autoRecoveryStatusLabel,
                      healthFailuresStatus: _healthFailuresStatusLabel,
                      stabilityNeedsAttention:
                          _connectionDegraded || !_batteryOptimizationIgnored,
                      kindLabel: _profileKindLabel,
                      displayName: _profileDisplayName,
                      countryFlag: _profileCountryFlag,
                      pingLabel: _profilePingLabel,
                      profileStabilityLabel: _profileStabilityLabel,
                      onPingAll: () => unawaited(_pingProfiles(_profiles)),
                      onPing: (profile) => unawaited(_pingProfile(profile)),
                      onRequestBackgroundAccess: () =>
                          unawaited(_requestBackgroundPowerAccess()),
                      onSmartRouteChanged: (enabled) =>
                          unawaited(_setSmartRouteRuDirect(enabled)),
                    ),
                    const SizedBox(height: 16),
                    _AppCenterPanel(
                      strings: s,
                      selectedTab: _supportTab,
                      onTabChanged: (tab) => setState(() => _supportTab = tab),
                      language: _language,
                      onLanguageChanged: (language) =>
                          unawaited(_setLanguage(language)),
                      onSupport: () => _openUrl(_telegramUrl),
                      onTelegram: () => _openUrl(_telegramUrl),
                      onVk: () => _openUrl(_vkUrl),
                      onDonate: () => _openUrl(_donateUrl),
                      onDeveloper: _emailDeveloper,
                      currentVersion: _appVersion,
                      availableVersion: _availableUpdate?.version,
                      updateMessage: _updateMessage,
                      updateBusy: _updateBusy,
                      updateProgress: _updateProgress,
                      onCheck: _checkAndInstallUpdate,
                      logs: _logs,
                      onExpansionChanged: (expanded) =>
                          unawaited(_setLogsExpanded(expanded)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
    final statusLabel = switch (status) {
      AurumVpnStatus.started =>
        degraded ? strings.connectionProblem : strings.connected,
      AurumVpnStatus.starting => strings.connecting,
      AurumVpnStatus.stopping => strings.disconnecting,
      _ => strings.stopped,
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
                          : YurichColors.shadow,
                      blurRadius: connected ? 28 + glowPower * 18 : 20,
                      spreadRadius: glowPower * 2,
                      offset: const Offset(0, 12),
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
    required this.keeperStatus,
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
  final String keeperStatus;
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
          keeperStatus: keeperStatus,
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
    required this.keeperStatus,
    required this.lastHealthStatus,
    required this.autoRecoveryStatus,
    required this.healthFailuresStatus,
    required this.stabilityNeedsAttention,
    required this.profileStabilityStatus,
    required this.onRefreshSubscriptions,
    required this.onRequestBackgroundAccess,
    required this.onSmartRouteChanged,
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
  final String keeperStatus;
  final String lastHealthStatus;
  final String autoRecoveryStatus;
  final String healthFailuresStatus;
  final bool stabilityNeedsAttention;
  final String? profileStabilityStatus;
  final VoidCallback onRefreshSubscriptions;
  final VoidCallback onRequestBackgroundAccess;
  final ValueChanged<bool> onSmartRouteChanged;
  final VoidCallback? onPing;

  @override
  Widget build(BuildContext context) {
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
                        value: strings.dnsCountryValue,
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
    required this.availableVersion,
    required this.message,
    required this.busy,
    required this.progress,
    required this.onCheck,
  });

  final _Strings strings;
  final String currentVersion;
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
                  strings.updateDescription,
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
                        strings.updateChannel,
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
                  label: Text(strings.checkUpdates),
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
        'В этой сборке поддерживаются VLESS Reality, NaiveProxy и Hysteria/Hysteria2.',
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
        'https://sub... или vless:// Reality или naive+https://... или hy2://...',
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
    dnsCountryValue: 'Через профиль',
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
        'Wi‑Fi/LTE: строгий TUN, FakeIP и DNS через выбранный профиль; keeper перепроверяет туннель без открытия приложения.',
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
            'Приложение использует единый сетевой режим для Wi‑Fi и LTE: DNS сервера VPN, аккуратное переподключение и устойчивую маршрутизацию через туннель.',
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
        'This build supports VLESS Reality, NaiveProxy, and Hysteria/Hysteria2.',
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
        'https://sub... or VLESS Reality or naive+https://... or hy2://...',
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
    dnsCountryValue: 'Through profile',
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
        'Wi-Fi/LTE: strict TUN, FakeIP, DNS through the selected profile, and a background keeper that checks the tunnel without opening the app.',
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
            'The Android client focuses on stable profiles: VLESS Reality, NaiveProxy, and Hysteria/Hysteria2. XHTTP, mKCP, TLS-only VLESS, and raw sing-box JSON are hidden in this build.',
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
            'The app uses one network baseline for Wi‑Fi and LTE: VPN server DNS, smoother reconnects, and stable tunnel routing.',
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
