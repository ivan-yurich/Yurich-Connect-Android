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

part 'home_screen_widgets.dart';
part 'home_screen_strings.dart';

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
const _appVersionFallback = '1.0.78';
const _nativeShortTimeout = Duration(seconds: 3);
const _nativeConfigTimeout = Duration(seconds: 5);
const _nativeStartTimeout = Duration(seconds: 8);
const _subscriptionReminderWindow = Duration(days: 5);
const _tunnelHealthProbeInterval = Duration(seconds: 105);
const _startupProbeRecheckDelay = Duration(seconds: 8);
const _trafficUiFlushInterval = Duration(seconds: 1);
const _notificationSyncMinInterval = Duration(seconds: 2);
const _profilePingCacheTtl = Duration(minutes: 10);
const _recentTrafficGrace = Duration(seconds: 70);
const _idleTunnelGrace = Duration(minutes: 3);
const _idleHealthProbeInterval = Duration(minutes: 5);
const _degradedHealthProbeInterval = Duration(seconds: 45);
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

enum _ProfileTab { all, vless, naive, hysteria, experimental }

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
    VpnProfileKind.pingTunnelExperimental => _ProfileTab.experimental,
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
      .where((profile) {
        if (profile.kind == VpnProfileKind.pingTunnelExperimental) {
          return true;
        }
        return profile.kind.isClientSupported;
      })
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
  DateTime? _lastIdleHealthCheckAt;
  DateTime? _lastResumeRecoveryAt;
  DateTime? _lastKeeperActionAt;
  DateTime? _lastNotificationSyncAt;
  DateTime _clockNow = DateTime.now();
  Map<String, dynamic>? _latestTrafficEvent;

  List<VpnProfile> _profiles = const [];
  final _profilePingMs = <String, int>{};
  final _profilePingText = <String, String>{};
  final _profilePingBusy = <String, bool>{};
  final _profilePingError = <String, String>{};
  final _profilePingCheckedAt = <String, DateTime>{};
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
  bool _manualDisconnectRequested = false;
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
  int _idleHealthChecks = 0;
  int _idleRecoveryCount = 0;
  String? _lastRecoverySource;
  String? _lastNetworkEvent;
  final _logs = <String>[];
  final _pendingLogs = <String>[];
  final _stabilityEvents = <String>[];
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

  String get _idleKeeperStatusLabel {
    final lastIdleAt = _lastIdleHealthCheckAt;
    if (lastIdleAt == null) {
      return s.idleKeeperReady;
    }
    return '${s.idleKeeperActive} · ${s.lastCheckAgo(_clockNow.difference(lastIdleAt))}';
  }

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

  bool _isTunnelIdle(DateTime now) {
    if (_status != AurumVpnStatus.started ||
        _autoReconnectInFlight ||
        _tunnelHealthCheckInFlight) {
      return false;
    }
    final lastTrafficAt = _lastTrafficAt;
    if (lastTrafficAt == null) {
      final connectedSince = _connectedSince;
      return connectedSince != null &&
          now.difference(connectedSince) > _idleTunnelGrace &&
          !_isTunnelStale(now);
    }
    return now.difference(lastTrafficAt) > _idleTunnelGrace &&
        !_isTunnelStale(now);
  }

  bool _shouldRunIdleHealthCheck(DateTime now) {
    if (!_isTunnelIdle(now)) {
      return false;
    }
    final lastIdleAt = _lastIdleHealthCheckAt;
    return lastIdleAt == null ||
        now.difference(lastIdleAt) > _idleHealthProbeInterval;
  }

  int _healthProbeAttemptsFor(String source) {
    if (source == 'app-resume' ||
        source.contains('idle') ||
        source.contains('stale') ||
        _tunnelHealthFailures > 0) {
      return 3;
    }
    return 2;
  }

  int _healthFailureThresholdFor(String source) {
    if (source == 'app-resume' ||
        source.contains('idle') ||
        source.contains('stale')) {
      return 1;
    }
    if (_tunnelHealthFailures > 0) {
      return 2;
    }
    return _tunnelHealthFailureThreshold;
  }

  Duration _healthProbeIntervalFor(String source) {
    if (_tunnelHealthFailures > 0 ||
        source.contains('stale') ||
        source.contains('resume')) {
      return _degradedHealthProbeInterval;
    }
    if (source.contains('idle')) {
      return _idleHealthProbeInterval;
    }
    return _tunnelHealthProbeInterval;
  }

  void _setKeeperAction(String action, {DateTime? at}) {
    _lastKeeperAction = action;
    _lastKeeperActionAt = at ?? DateTime.now();
    _recordStabilityEvent('keeper:$action', at: _lastKeeperActionAt);
  }

  void _recordStabilityEvent(String message, {DateTime? at}) {
    final eventAt = at ?? DateTime.now();
    final cleaned = _redactSensitive(_cleanLog(message));
    if (cleaned.isEmpty) {
      return;
    }
    _stabilityEvents.add('${eventAt.toIso8601String()} $cleaned');
    if (_stabilityEvents.length > 60) {
      _stabilityEvents.removeRange(0, _stabilityEvents.length - 60);
    }
  }

  ConnectionUiState get _connectionUiState {
    final profile = _selectedProfile;
    final connectionStatus = _effectiveConnectionStatus;

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

  ConnectionStatus get _effectiveConnectionStatus {
    if (_autoReconnectInFlight) {
      return ConnectionStatus.reconnecting;
    }
    if (_status == AurumVpnStatus.starting ||
        _status == AurumVpnStatus.stopping) {
      return ConnectionStatus.connecting;
    }
    if (_status == AurumVpnStatus.started) {
      if (_connectionDegraded) {
        return ConnectionStatus.degraded;
      }
      if (_isTunnelIdle(DateTime.now())) {
        return ConnectionStatus.idle;
      }
      return ConnectionStatus.connected;
    }
    if (_autoRecoveryArmed && (_lastError?.isNotEmpty ?? false)) {
      return ConnectionStatus.failed;
    }
    return ConnectionStatus.disconnected;
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
      _lastNetworkEvent = 'app-resume';
      unawaited(_refreshBatteryOptimizationStatus());
      unawaited(_handleResumeRecovery());
    }
  }

  Future<void> _handleResumeRecovery() async {
    _lastResumeRecoveryAt = DateTime.now();
    await Future<void>.delayed(_resumeHealthCheckDelay);
    if (!mounted ||
        _stoppingByUser ||
        _manualDisconnectRequested ||
        !_autoRecoveryArmed) {
      return;
    }

    final status = await _refreshVpnStatus();
    if (!mounted ||
        _stoppingByUser ||
        _manualDisconnectRequested ||
        !_autoRecoveryArmed) {
      return;
    }

    if (status == AurumVpnStatus.stopped) {
      _markUnexpectedStop('app-resume');
      return;
    }

    if (status == AurumVpnStatus.started) {
      _nextTunnelHealthCheckAt = DateTime.now();
      _setKeeperAction('resume-check');
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
    final manualDisconnectRequested = await _store
        .loadManualDisconnectRequested();
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
      _manualDisconnectRequested = manualDisconnectRequested;
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
                if (!_manualDisconnectRequested) {
                  _autoRecoveryArmed = true;
                }
                _connectedSince ??= now;
                _lastHealthyAt ??= now;
                _lastTrafficAt ??= now;
                _clockNow = now;
                _ignoreStoppedUntil = now.add(const Duration(seconds: 4));
              }
              if (status == AurumVpnStatus.stopped && !_autoRecoveryArmed) {
                _connectedSince = null;
                _lastTrafficAt = null;
                _lastHealthyAt = null;
                _lastIdleHealthCheckAt = null;
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
            if (status == AurumVpnStatus.started &&
                _manualDisconnectRequested &&
                !_stoppingByUser) {
              unawaited(_enforceManualDisconnect('status-event'));
            }
            if (recoverUnexpectedStop) {
              _markUnexpectedStop('status-event');
            }
            unawaited(_syncConnectionNotification(force: true));
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
          _trafficFlushTimer ??= Timer(_trafficUiFlushInterval, () {
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
              final nextUplink =
                  latest['formattedUplinkSpeed'] as String? ?? _uplink;
              final nextDownlink =
                  latest['formattedDownlinkSpeed'] as String? ?? _downlink;
              final nextSessionTotal =
                  latest['formattedSessionTotal'] as String? ?? _sessionTotal;
              final displayChanged =
                  nextUplink != _uplink ||
                  nextDownlink != _downlink ||
                  nextSessionTotal != _sessionTotal;
              final healthChanged =
                  hasTraffic &&
                  _status == AurumVpnStatus.started &&
                  (_tunnelHealthFailures != 0 || _lastHealthyAt == null);

              void applyTrafficUpdate() {
                _uplink = nextUplink;
                _downlink = nextDownlink;
                _sessionTotal = nextSessionTotal;
                if (sessionTotal >= _lastSessionTrafficBytes) {
                  _lastSessionTrafficBytes = sessionTotal;
                }
                if (hasTraffic && _status == AurumVpnStatus.started) {
                  _lastTrafficAt = now;
                  _lastHealthyAt = now;
                  _tunnelHealthFailures = 0;
                }
              }

              if (displayChanged || healthChanged) {
                setState(applyTrafficUpdate);
              } else {
                applyTrafficUpdate();
              }
              if (displayChanged) {
                unawaited(_syncConnectionNotification());
              }
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
            if (!_manualDisconnectRequested) {
              _autoRecoveryArmed = true;
            }
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
        if (status == AurumVpnStatus.started &&
            _manualDisconnectRequested &&
            !_stoppingByUser) {
          unawaited(_enforceManualDisconnect('init-status'));
        }
        unawaited(_syncConnectionNotification(force: true));
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
    _recordStabilityEvent('engine-stream-error:$source:$errorText');
    _queueLog('Engine stream error [$source]: $errorText');
    if (stackTrace != null) {
      _queueLog('Engine stream stack [$source]: $stackTrace');
    }
    if (!mounted) {
      return;
    }
    final shouldProbeNow =
        _status == AurumVpnStatus.started &&
        !_manualDisconnectRequested &&
        !_stoppingByUser;
    setState(() {
      _lastError = errorText;
      if (_status == AurumVpnStatus.started) {
        _tunnelHealthFailures += 1;
      }
    });
    if (shouldProbeNow) {
      _nextTunnelHealthCheckAt = DateTime.now();
      unawaited(_refreshTunnelHealth(source: 'engine-stream-$source'));
    }
  }

  Future<void> _syncConnectionNotification({bool force = false}) async {
    if (_notificationSyncInFlight) {
      return;
    }
    final now = DateTime.now();
    final lastSyncAt = _lastNotificationSyncAt;
    if (!force &&
        lastSyncAt != null &&
        now.difference(lastSyncAt) < _notificationSyncMinInterval) {
      return;
    }
    _notificationSyncInFlight = true;
    _lastNotificationSyncAt = now;
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
      unawaited(_pingProfile(profile, force: true));
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

    await _store.saveManualDisconnectRequested(false);
    if (!mounted) {
      return;
    }
    setState(() {
      _manualDisconnectRequested = false;
    });
    unawaited(_refreshBatteryOptimizationStatus(prompt: true));
    _autoRecoveryArmed = true;
    await _runBusy(() async {
      try {
        if (_selectedProfileId != profile.id) {
          setState(() {
            _selectedProfileId = profile.id;
            _profileTab = _profileTabForKind(profile.kind);
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
    _lastIdleHealthCheckAt = null;
    _lastRecoverySource = null;
    _lastNetworkEvent = 'manual-start';
    _lastSessionTrafficBytes = 0;
    _idleHealthChecks = 0;
    _idleRecoveryCount = 0;
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
    _autoReconnectInFlight = false;
    _nextAutoReconnectAt = null;
    _autoReconnectAttempts = 0;
    await _store.saveManualDisconnectRequested(true);
    if (!mounted) {
      return;
    }
    setState(() {
      _manualDisconnectRequested = true;
    });
    await _runBusy(() => _stopVpnCore(), message: s.disconnectingVpn);
  }

  Future<void> _enforceManualDisconnect(String source) async {
    if (!mounted || _stoppingByUser) {
      return;
    }

    _queueLog(
      'Manual disconnect guard: native VPN reported Started from $source; '
      'stopping again.',
    );
    _autoRecoveryArmed = false;
    _nextAutoReconnectAt = null;
    _autoReconnectAttempts = 0;
    await _stopVpnCore(updateMessage: true);
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
            _lastIdleHealthCheckAt = null;
            _lastRecoverySource = null;
            _lastNetworkEvent = 'manual-stop';
            _lastSessionTrafficBytes = 0;
            _idleHealthChecks = 0;
            _idleRecoveryCount = 0;
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
    if (!mounted ||
        _busy ||
        _statusWatchdogInFlight ||
        _manualDisconnectRequested) {
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
        final idleCheck = _shouldRunIdleHealthCheck(now);
        if (stale) {
          _nextTunnelHealthCheckAt = now;
          _setKeeperAction('watchdog-stale-check');
          _queueLog('VPN watchdog: stale tunnel check forced.');
        } else if (idleCheck) {
          _lastIdleHealthCheckAt = now;
          _idleHealthChecks += 1;
          _nextTunnelHealthCheckAt = now;
          _setKeeperAction('watchdog-idle-check');
          _queueLog('VPN watchdog: idle tunnel check forced.');
        }
        await _refreshTunnelHealth(
          source: stale
              ? 'watchdog-stale'
              : idleCheck
              ? 'watchdog-idle'
              : 'watchdog',
        );
      }
    } finally {
      _statusWatchdogInFlight = false;
    }
  }

  void _markUnexpectedStop(String source) {
    if (!mounted ||
        _stoppingByUser ||
        _manualDisconnectRequested ||
        !_autoRecoveryArmed) {
      return;
    }

    final profile = _selectedProfile;
    _recordStabilityEvent('unexpected-stop:$source');
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
    if (_autoReconnectInFlight ||
        _tunnelHealthCheckInFlight ||
        _manualDisconnectRequested ||
        !mounted) {
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
      _nextTunnelHealthCheckAt = now.add(_healthProbeIntervalFor(source));
      unawaited(
        _recordProfileStability(
          profile,
          (stats) => stats.recordHealthy(at: lastTrafficAt),
        ),
      );
      return;
    }

    _nextTunnelHealthCheckAt = now.add(_healthProbeIntervalFor(source));
    _tunnelHealthCheckInFlight = true;
    try {
      final healthy = await _probeLocalMixedProxy(
        attempts: _healthProbeAttemptsFor(source),
        logFailures: false,
      );
      if (!mounted ||
          _manualDisconnectRequested ||
          _status != AurumVpnStatus.started) {
        return;
      }

      if (healthy) {
        _tunnelHealthFailures = 0;
        _lastHealthyAt = DateTime.now();
        if (source.contains('idle')) {
          _lastIdleHealthCheckAt = _lastHealthyAt;
        }
        _setKeeperAction('probe-ok:$source', at: _lastHealthyAt);
        unawaited(
          _recordProfileStability(profile, (stats) => stats.recordHealthy()),
        );
        return;
      }

      _tunnelHealthFailures += 1;
      final failureThreshold = _healthFailureThresholdFor(source);
      _setKeeperAction('probe-failed:$source');
      unawaited(
        _recordProfileStability(
          profile,
          (stats) => stats.recordHealthFailure('health-probe:$source'),
        ),
      );
      _queueLog(
        'VPN watchdog: health probe failed #$_tunnelHealthFailures/'
        '$failureThreshold from $source for ${profile.name}.',
      );

      if (_tunnelHealthFailures >= failureThreshold) {
        if (_manualDisconnectRequested) {
          return;
        }
        _tunnelHealthFailures = 0;
        _queueLog(
          'VPN watchdog: tunnel is unhealthy, reconnecting ${profile.name}.',
        );
        if (source.contains('idle') || source.contains('stale')) {
          _idleRecoveryCount += 1;
        }
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
    if (_autoReconnectInFlight ||
        _busy ||
        _stoppingByUser ||
        _manualDisconnectRequested ||
        !mounted) {
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
    _lastRecoverySource = source;
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
      if (!mounted || _stoppingByUser || _manualDisconnectRequested) {
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

      if (!mounted || _manualDisconnectRequested) {
        return;
      }
      await _startVpnCore(profile);
      _setKeeperAction('reconnect-ok:$source#$attempt');
      _lastHealthyAt = DateTime.now();
      _lastError = null;
      _tunnelHealthFailures = 0;
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

  Future<void> _pingProfiles(
    List<VpnProfile> profiles, {
    bool force = false,
  }) async {
    if (_pingAllInFlight || profiles.isEmpty) {
      return;
    }

    final orderedProfiles = profiles.toList(growable: false)
      ..sort((a, b) {
        final aSelected = a.id == _selectedProfileId;
        final bSelected = b.id == _selectedProfileId;
        if (aSelected == bSelected) {
          return a.name.compareTo(b.name);
        }
        return aSelected ? -1 : 1;
      });

    _pingAllInFlight = true;
    try {
      for (final profile in orderedProfiles.take(12)) {
        if (!mounted) {
          return;
        }
        await _pingProfile(profile, force: force);
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    } finally {
      _pingAllInFlight = false;
    }
  }

  Future<void> _pingProfile(VpnProfile profile, {bool force = false}) async {
    final server = profile.server?.trim();
    final port = profile.port ?? 443;
    if (server == null || server.isEmpty || port <= 0) {
      return;
    }
    if (_profilePingBusy[profile.id] == true) {
      return;
    }
    final checkedAt = _profilePingCheckedAt[profile.id];
    if (!force &&
        checkedAt != null &&
        DateTime.now().difference(checkedAt) < _profilePingCacheTtl) {
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
      _profilePingCheckedAt[profile.id] = DateTime.now();
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
        VpnProfileKind.pingTunnelExperimental => 'pingtunnel',
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
      await _updateService.installApk(
        file,
        currentBuildNumber: int.tryParse(_appBuildNumber),
      );
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
              _openUrl(
                (_availableUpdate?.downloadUrl ??
                        AppUpdateService.latestApkDownloadUri)
                    .toString(),
              ),
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
    final stabilityEventStart = _stabilityEvents.length > 30
        ? _stabilityEvents.length - 30
        : 0;
    final recentStabilityEvents = _stabilityEvents.skip(stabilityEventStart);
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
      'connection_state: ${_effectiveConnectionStatus.name}',
      'connection_degraded: $_connectionDegraded',
      'connection_idle: ${_isTunnelIdle(now)}',
      'connection_stale: ${_isTunnelStale(now)}',
      'manual_disconnect_requested: $_manualDisconnectRequested',
      'message: ${_redactSensitive(_message)}',
      if (_lastError != null) 'last_error: $_lastError',
      'uptime: ${_formatDuration(_connectedDuration)}',
      'auto_recovery_armed: $_autoRecoveryArmed',
      'auto_reconnect_attempts: $_autoReconnectAttempts',
      'health_failures: $_tunnelHealthFailures',
      'idle_health_checks: $_idleHealthChecks',
      'idle_recoveries: $_idleRecoveryCount',
      if (_lastRecoverySource != null)
        'last_recovery_source: $_lastRecoverySource',
      if (_lastNetworkEvent != null) 'last_network_event: $_lastNetworkEvent',
      if (_lastKeeperAction != null) 'keeper_last_action: $_lastKeeperAction',
      if (_lastKeeperActionAt != null)
        'keeper_last_action_local: ${_lastKeeperActionAt!.toIso8601String()}',
      if (_lastResumeRecoveryAt != null)
        'last_resume_recovery_local: ${_lastResumeRecoveryAt!.toIso8601String()}',
      if (_lastIdleHealthCheckAt != null)
        'last_idle_health_check_local: ${_lastIdleHealthCheckAt!.toIso8601String()}',
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
      'stability_events:',
      if (recentStabilityEvents.isEmpty) 'none' else ...recentStabilityEvents,
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
      final proxyTls = (proxy['tls'] as Map?)?.cast<String, dynamic>();
      final proxyReality = (proxyTls?['reality'] as Map?)
          ?.cast<String, dynamic>();
      final proxyUtls = (proxyTls?['utls'] as Map?)?.cast<String, dynamic>();
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
        if (proxy['type'] == 'vless')
          'mode=${proxyReality?['enabled'] == true ? 'reality-tcp' : 'tls'}',
        if (proxy['type'] == 'vless') 'flow=${proxy['flow'] ?? 'default'}',
        if (proxy['type'] == 'vless')
          'sni=${proxyTls?['server_name'] ?? 'unknown'}',
        if (proxy['type'] == 'vless')
          'utls=${proxyUtls?['fingerprint'] ?? 'default'}',
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
                      idleKeeperStatus: _idleKeeperStatusLabel,
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
                      onPingAll: () =>
                          unawaited(_pingProfiles(_profiles, force: true)),
                      onPing: (profile) =>
                          unawaited(_pingProfile(profile, force: true)),
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
