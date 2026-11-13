import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/connection_status.dart';
import '../models/connection_ui_state.dart';
import '../models/dns_protection_mode.dart';
import '../models/profile_network_stability.dart';
import '../models/profile_stability.dart';
import '../models/vpn_profile.dart';
import '../services/app_update_service.dart';
import '../services/auto_failover_order.dart';
import '../services/direct_latency_probe.dart';
import '../services/local_connection_incidents.dart';
import '../services/local_proxy_health_probe.dart';
import '../services/kill_switch_service.dart';
import '../services/kill_switch_http_policy.dart';
import '../services/fixed_size_batches.dart';
import '../services/power_manager_service.dart';
import '../services/preferred_first.dart';
import '../services/profile_auto_selector.dart';
import '../services/profile_country_resolver.dart';
import '../services/profile_geo_service.dart';
import '../services/profile_importer.dart';
import '../services/runtime_config_matcher.dart';
import '../services/profile_engine_selector.dart';
import '../services/profile_store.dart';
import '../services/sensitive_data_redactor.dart';
import '../services/soak_counter_publish_cadence.dart';
import '../services/on_device_diagnostics.dart';
import '../services/protocol_display_mapper.dart';
import '../services/protocol_test_metadata.dart';
import '../services/proxy_server_probe.dart';
import '../services/sing_box_log_filter.dart';
import '../services/smart_route_rules.dart';
import '../services/smart_route_apps_service.dart';
import '../services/tls_pin_policy.dart';
import '../services/sing_box_config_builder.dart';
import '../services/vpn_engine.dart';
import '../services/vpn_reconnect_policy.dart';
import '../services/vpn_session_controller.dart';
import '../services/subscription_profile_reconciler.dart';
import '../services/xray_config_builder.dart';
import '../theme/yurich_theme.dart';
import '../utils/traffic_formatter.dart';
import 'qr_scan_screen.dart';
import 'diagnostics_panel.dart';
import 'kill_switch_panel.dart';
import 'smart_route_apps_dialog.dart';
import 'tv_home_screen.dart';

part 'home_screen_widgets.dart';
part 'home_screen_strings.dart';
part 'home_screen_mobile.dart';
part 'home_screen_hermes_settings.dart';

const _appName = 'Yurich Connect';
const _telegramUrl = 'https://t.me/ivan_it_net';
const _vkUrl = 'https://vk.com/ivan_yurievich_it';
const _donateUrl = 'https://dzen.ru/ivanyurievich?donate=true';
const _supportEmail = 'ai@ivan-it.net';
const _appVersionFallback = '1.0.108';
const _nativeShortTimeout = Duration(seconds: 3);
const _autoPassBudget = Duration(minutes: 3);
const _nativeConfigTimeout = Duration(seconds: 10);
const _subscriptionReminderWindow = Duration(days: 5);
const _tunnelHealthProbeInterval = Duration(seconds: 105);
const _trafficUiFlushInterval = Duration(seconds: 1);
const _notificationSyncMinInterval = Duration(seconds: 2);
const _profilePingCacheTtl = Duration(minutes: 10);
const _recentTrafficGrace = Duration(seconds: 70);
const _idleTunnelGrace = Duration(minutes: 3);
const _idleHealthProbeInterval = Duration(minutes: 5);
const _degradedHealthProbeInterval = Duration(seconds: 45);
const _resumeHealthCheckDelay = Duration(seconds: 2);
const _resumeNetworkSettleDelay = Duration(seconds: 5);
const _resumeRecoveryMinInterval = Duration(seconds: 20);
const _resumeWatchdogQuietWindow = Duration(seconds: 35);
const _networkChangingSettleWindow = Duration(seconds: 35);
const _nativeActivityGrace = Duration(seconds: 90);
const _networkStatsTrafficMinDelta = 1024 * 1024;
const _networkStatsTrafficMinInterval = Duration(minutes: 2);
const _staleTunnelGrace = Duration(minutes: 5);
const _tunnelHealthFailureThreshold = 4;
const _maxStoredLogs = 180;
const _maxPendingLogs = 240;
const _vpnDisclosureVersion = 1;
const _manualUpdateCheckTimeout = Duration(seconds: 60);
const _soakBridgeChannel = MethodChannel('online.dnsai.ivanvpn/soak');
const _privacyPolicyUrl =
    'https://github.com/ivan-yurich/Yurich-Connect-Android/blob/main/PRIVACY.md';
const _playStoreUrl =
    'https://play.google.com/store/apps/details?id=online.dnsai.ivanvpn';
final _logAnsiEscapePattern = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');

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

enum _SupportTab { help, community }

class _ProfileConnectionBlocked implements Exception {
  const _ProfileConnectionBlocked(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef _AutoPhysicalNetwork = ({String key, String type, bool confirmed});

final class _AutoNetworkChanged implements Exception {
  const _AutoNetworkChanged();
}

final class _AutoCandidateUnavailable implements Exception {
  const _AutoCandidateUnavailable();
}

final class _AutoPassExhausted implements Exception {
  const _AutoPassExhausted();
}

final class _AutoNetworkUnavailable implements Exception {
  const _AutoNetworkUnavailable();
}

List<VpnProfile> _clientSupportedProfiles(List<VpnProfile> profiles) {
  return profiles
      .where((profile) => profile.kind.isClientSupported)
      .toList(growable: false);
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.tvMode = false});

  final bool tvMode;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _vpnEngine = createVpnEngine();
  final _store = ProfileStore();
  final _importer = ProfileImporter();
  final _configBuilder = SingBoxConfigBuilder();
  final _subscriptionProfileReconciler = const SubscriptionProfileReconciler();
  final _xrayConfigBuilder = XrayConfigBuilder();
  final _autoSelector = const ProfileAutoSelector();
  final _updateService = AppUpdateService();
  final _powerManagerService = PowerManagerService();
  final _localIncidents = const LocalConnectionIncidentsService();
  final _geoService = ProfileGeoService();
  final _sessionController = VpnSessionController();
  final _soakCounterPublishCadence = SoakCounterPublishCadence();
  final _manualController = TextEditingController();
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>?
  _connectionErrorSnackBar;

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
  List<VpnProfile> _storedProfiles = const [];
  final _profilePingMs = <String, int>{};
  final _profileProbeResults = <String, ServerProbeResult>{};
  final _profilePingBusy = <String, bool>{};
  final _profilePingCheckedAt = <String, DateTime>{};
  final _activeProfileProbeCancels = <VoidCallback>{};
  int _profileProbeEpoch = 0;
  final _lastSuccessfulPlanByProfileId = <String, String>{};
  Map<String, ProfileStabilityStats> _profileStabilityStats = const {};
  Map<String, Map<String, ProfileNetworkStabilityStats>>
  _profileNetworkStabilityStats = const {};
  String? _selectedProfileId;
  _AppLanguage _language = _AppLanguage.ru;
  bool _automaticProfileSelection = true;
  bool? _directLatencyAllowed;
  VpnSessionOperation? _autoConnectPreparation;
  bool get _preparingAutoConnect => _autoConnectPreparation != null;
  bool _stopProtectionCheck = false;
  bool _directConsentVisible = false;
  DirectLatencyProbe? _directLatencyProbe;
  final _directReadings =
      <String, ({DirectLatencyReading reading, String network, DateTime at})>{};
  String? _probePhysicalNetwork;
  _MobilePage _mobilePage = _MobilePage.home;
  String? _unconfirmedSwitchProfileId;
  _SupportTab _supportTab = _SupportTab.help;
  String _status = AurumVpnStatus.stopped;
  String _uplink = '0 B/s';
  String _downlink = '0 B/s';
  String _sessionTotal = '0 B';
  String _message = 'Готов к импорту подписки';
  String _appVersion = _appVersionFallback;
  String _appBuildNumber = '';
  AppDistributionChannel _distributionChannel = AppDistributionChannel.unknown;
  String? _lastError;
  // A failed VPN command can finish with native status Stopped. Keep that
  // distinct from an intentional disconnect on the mobile power button.
  bool _vpnUiCommandFailed = false;
  String? _lastVpnFailureCategory;
  bool _busy = false;
  bool _updateBusy = false;
  bool _subscriptionRefreshBusy = false;
  bool _stoppingByUser = false;
  bool _statusWatchdogInFlight = false;
  bool _tunnelHealthCheckInFlight = false;
  bool _notificationSyncInFlight = false;
  bool _notificationSyncPending = false;
  bool _autoRecoveryArmed = false;
  bool _manualDisconnectRequested = false;
  bool _pingAllInFlight = false;
  bool _countryResolveInFlight = false;
  Future<void> _profilePersistTail = Future<void>.value();
  bool _runtimeReconcileInFlight = false;
  bool _runtimeReconciled = false;
  bool _nativeRecoveryStarting = false;
  bool _soakProfilesLoaded = false;
  bool _soakVpnInitialized = false;
  bool _soakReadyAnnounced = false;
  bool _logsExpanded = false;
  bool _uiForeground = true;
  String? _lastConfigSummary;
  String? _lastKeeperAction;
  String? _updateMessage;
  AppUpdateInfo? _availableUpdate;
  double? _updateProgress;
  String? _updateNoticeShownForVersion;
  bool _updateNoticeCheckInFlight = false;
  final _updateNoticeClock = Stopwatch()..start();
  Duration? _lastUpdateNoticeAttempt;
  bool? _batteryOptimizationIgnored;
  bool _batteryOptimizationCheckInFlight = false;
  LocalIncidentState _localIncidentState = const LocalIncidentState.disabled();
  bool _localIncidentSettingsBusy = false;
  bool _smartRouteRuDirect = false;
  bool _smartRoutePreferenceLoaded = false;
  bool _smartRouteSettingsBusy = false;
  late final Future<void> _initialSettingsLoad;
  final _smartRouteApps = const SmartRouteAppsService();
  final _killSwitchService = const KillSwitchService();
  KillSwitchState _killSwitchState = const KillSwitchState();
  bool _killSwitchApplying = false;
  DnsProtectionMode _dnsProtectionMode = DnsProtectionMode.stable;
  DateTime? _nextTunnelHealthCheckAt;
  DateTime? _networkChangingUntil;
  DateTime? _lastNetworkSnapshotAt;
  DateTime? _lastNativeActivityAt;
  DateTime? _lastNetworkStatsTrafficSavedAt;
  int _tunnelHealthFailures = 0;
  int _lastSessionTrafficBytes = 0;
  int _nativeSessionTotalBytes = 0;
  int _nativeUplinkSpeedBytes = 0;
  int _nativeDownlinkSpeedBytes = 0;
  int _soakSessionGeneration = 0;
  int _lastNetworkStatsTrafficBytes = 0;
  int _networkGenerationId = 0;
  int _idleHealthChecks = 0;
  int _idleRecoveryCount = 0;
  String? _lastRecoverySource;
  String? _lastNetworkEvent;
  String _networkType = 'unknown';
  String _networkFingerprint = '';
  final _logs = <String>[];
  final _pendingLogs = <String>[];
  final _stabilityEvents = <String>[];
  _Strings get s => _Strings.forLanguage(_language);

  Duration? get _connectedDuration {
    final since = _connectedSince;
    if (since == null || _status != AurumVpnStatus.started) {
      return null;
    }
    final now = _uiForeground ? _clockNow : DateTime.now();
    final duration = now.difference(since);
    return duration.isNegative ? Duration.zero : duration;
  }

  bool get _networkChanging => _isNetworkChanging(DateTime.now());
  bool get _connectionQueueActive => _sessionController.hasPendingOperations;
  bool get _userStopQueued =>
      _connectionQueueActive &&
      _manualDisconnectRequested &&
      !_sessionController.desiredRunning;
  bool get _pendingNativeStart => _connectionQueueActive
      ? _sessionController.desiredRunning
      : !_manualDisconnectRequested && _status == AurumVpnStatus.starting;
  bool get _canCancelVpnStart => _preparingAutoConnect || _pendingNativeStart;

  String get _networkTypeLabel {
    return switch (_networkType) {
      'wifi' => 'Wi-Fi',
      'cellular' => 'LTE/5G',
      'ethernet' => 'Ethernet',
      'none' => 'Нет сети',
      'unknown' => 'Неизвестно',
      _ => _networkType,
    };
  }

  VpnProfile? get _selectedProfile {
    for (final profile in _profiles) {
      if (profile.id == _selectedProfileId) {
        return profile;
      }
    }
    return _profiles.isEmpty ? null : _profiles.first;
  }

  VpnProfile? get _explicitSelectedProfile {
    final selectedId = _selectedProfileId;
    if (selectedId == null) {
      return null;
    }
    for (final profile in _profiles) {
      if (profile.id == selectedId) {
        return profile;
      }
    }
    return null;
  }

  bool get _connected =>
      _status == AurumVpnStatus.started || _status == AurumVpnStatus.starting;

  bool get _smartRoutePausedByKillSwitch =>
      _killSwitchState.requested ||
      _killSwitchState.alwaysOn ||
      _killSwitchState.lockdown ||
      _killSwitchState.strictRuntime;

  bool get _nativeOwnsTunnelHealth =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _connectionDegraded {
    if (_stoppingByUser) {
      return false;
    }
    if (_networkChanging) {
      return false;
    }
    if (_tunnelHealthFailures > 0) {
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
    // Android's Started is config-bound and confirmed by the native HTTPS quorum.
    // Quiet UI counters do not override that service-owned readiness decision.
    if (_nativeOwnsTunnelHealth) {
      return false;
    }
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
    if (_status != AurumVpnStatus.started || _tunnelHealthCheckInFlight) {
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
    if (source == 'app-resume') {
      return 2;
    }
    if (source.contains('idle') || source.contains('stale')) {
      return 2;
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

  bool _isResumeRecoveryQuietWindow(DateTime now) {
    final lastResumeAt = _lastResumeRecoveryAt;
    return lastResumeAt != null &&
        now.difference(lastResumeAt) < _resumeWatchdogQuietWindow;
  }

  bool _isNetworkChanging(DateTime now) {
    final changingUntil = _networkChangingUntil;
    return changingUntil != null && now.isBefore(changingUntil);
  }

  String _networkTypeFromSnapshot(Map<String, dynamic> snapshot) {
    final raw = '${snapshot['type'] ?? 'unknown'}'.trim().toLowerCase();
    return raw.isEmpty ? 'unknown' : raw;
  }

  int _networkGenerationFromSnapshot(Map<String, dynamic> snapshot) {
    return _eventInt(snapshot['generation']);
  }

  bool _applyNetworkSnapshot(
    Map<String, dynamic> snapshot, {
    required String source,
    DateTime? at,
  }) {
    if (snapshot.isEmpty) {
      return false;
    }

    final now = at ?? DateTime.now();
    final nextType = _networkTypeFromSnapshot(snapshot);
    final nextGeneration = _networkGenerationFromSnapshot(snapshot);
    final nextFingerprint = '${snapshot['fingerprint'] ?? ''}'.trim();
    final generationChanged =
        nextGeneration > 0 && nextGeneration != _networkGenerationId;
    final fingerprintChanged =
        nextFingerprint.isNotEmpty &&
        _networkFingerprint.isNotEmpty &&
        nextFingerprint != _networkFingerprint;
    final changed = generationChanged || fingerprintChanged;
    final probePath = snapshot['probePhysicalNetwork'] as String?;
    final probePathChanged =
        probePath != null && _probePhysicalNetwork != probePath;

    void apply() {
      _networkType = nextType;
      if (nextGeneration > 0) {
        _networkGenerationId = nextGeneration;
      }
      if (nextFingerprint.isNotEmpty) {
        _networkFingerprint = nextFingerprint;
      }
      if (probePathChanged || changed) {
        _cancelDirectLatency(clearReadings: true);
        _probePhysicalNetwork = probePath ?? _probePhysicalNetwork;
      }
      _lastNetworkSnapshotAt = now;
      if (changed) {
        _invalidateProfileProbes();
        _networkChangingUntil = now.add(_networkChangingSettleWindow);
        _lastNetworkEvent = '$source:$nextType#g$_networkGenerationId';
        _lastNetworkStatsTrafficBytes = _lastSessionTrafficBytes;
        _lastNetworkStatsTrafficSavedAt = null;
        _tunnelHealthFailures = 0;
        _nextTunnelHealthCheckAt = _networkChangingUntil;
      }
    }

    if (mounted && (changed || probePathChanged)) {
      setState(apply);
    } else {
      apply();
    }

    if (changed) {
      _setKeeperAction('network-changing:$source');
      _recordStabilityEvent(
        'network-change:$source:type=$nextType:g=$_networkGenerationId',
      );
      _queueLog(
        'Network changed from $source: type=$nextType generation=$_networkGenerationId.',
      );
    }

    return changed;
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
      countryCode: _profileCountryCode(profile),
      pingMs: profile == null ? null : _profilePingMs[profile.id],
      latencyLabel: profile == null ? null : _profilePingLabel(profile),
      uploadSpeed: _uplink,
      downloadSpeed: _downlink,
      totalTraffic: _sessionTotal,
      sessionDuration: _connectedDuration == null
          ? null
          : TrafficFormatter.formatDuration(_connectedDuration!),
    );
  }

  ConnectionStatus get _effectiveConnectionStatus {
    if (_status == AurumVpnStatus.starting && _autoRecoveryArmed) {
      return ConnectionStatus.reconnecting;
    }
    if (_status == AurumVpnStatus.starting ||
        _status == AurumVpnStatus.stopping) {
      return ConnectionStatus.connecting;
    }
    if (_status == AurumVpnStatus.started) {
      if (_networkChanging) {
        return ConnectionStatus.networkChanging;
      }
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
    return ProfileCountryResolver.displayCountryName(profile);
  }

  String? _profileCountryCode(VpnProfile? profile) {
    return ProfileCountryResolver.displayCountryCode(profile);
  }

  @override
  void initState() {
    super.initState();
    _soakBridgeChannel.setMethodCallHandler(_handleSoakBridgeCall);
    WidgetsBinding.instance.addObserver(this);
    _uiForeground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (_uiForeground) {
      _startUptimeTimer();
    }
    _initialSettingsLoad = _startBootTask(
      'load',
      _load,
      timeout: const Duration(seconds: 12),
    );
    unawaited(
      _startBootTask('init-vpn', _initVpn, timeout: const Duration(seconds: 8)),
    );
    if (!widget.tvMode && _localIncidents.available) {
      unawaited(_loadLocalIncidentState());
    }
    unawaited(
      _startBootTask(
        'kill-switch',
        _refreshKillSwitchState,
        timeout: const Duration(seconds: 4),
      ),
    );
    if (_uiForeground) {
      _startStatusWatchdog();
    }
    _subscriptionReminderTimer = Timer.periodic(
      const Duration(hours: 6),
      (_) => unawaited(_showSubscriptionRenewalReminder(_profiles)),
    );
  }

  void _startUptimeTimer() {
    _uptimeTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_uiForeground || _status != AurumVpnStatus.started) {
        return;
      }
      setState(() => _clockNow = DateTime.now());
    });
  }

  void _startStatusWatchdog() {
    _statusWatchdogTimer ??= Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(_refreshStatusWatchdog());
      unawaited(_refreshKillSwitchState());
    });
  }

  Future<void> _startBootTask(
    String label,
    Future<void> Function() task, {
    required Duration timeout,
  }) async {
    try {
      await task().timeout(timeout);
    } on Object catch (error, stackTrace) {
      final errorText = _redactSensitive('$error');
      _recordStabilityEvent('boot-task-error:$label:$errorText');
      _queueLog('Boot task failed [$label]: $errorText');
      _queueLog(_redactSensitive(stackTrace.toString().split('\n').first));
    }
  }

  @override
  void dispose() {
    _invalidateProfileProbes();
    _geoService.close();
    _soakBridgeChannel.setMethodCallHandler(null);
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
    _sessionController.dispose();
    _updateNoticeClock.stop();
    unawaited(_vpnEngine.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _uiForeground = state == AppLifecycleState.resumed;
    if (_uiForeground) {
      _startUptimeTimer();
      _startStatusWatchdog();
      setState(() => _clockNow = DateTime.now());
      _lastNetworkEvent = 'app-resume';
      if (_mobilePage == _MobilePage.settings) {
        unawaited(_refreshBatteryOptimizationStatus());
      }
      unawaited(_refreshKillSwitchState(applyIfNeeded: true));
      unawaited(_refreshNetworkSnapshot('app-resume'));
      unawaited(_handleResumeRecovery());
      unawaited(_checkLatestUpdateNotice());
    } else {
      KillSwitchHttpPolicy.cancelDirectRequests();
      _cancelDirectLatency(clearReadings: true);
      _uptimeTimer?.cancel();
      _uptimeTimer = null;
      _statusWatchdogTimer?.cancel();
      _statusWatchdogTimer = null;
    }
  }

  Future<void> _handleResumeRecovery() async {
    final startedAt = DateTime.now();
    final previousResumeAt = _lastResumeRecoveryAt;
    if (previousResumeAt != null &&
        startedAt.difference(previousResumeAt) < _resumeRecoveryMinInterval) {
      _recordStabilityEvent('resume-recovery:debounced');
      return;
    }
    _lastResumeRecoveryAt = startedAt;
    await Future<void>.delayed(_resumeHealthCheckDelay);
    if (!mounted ||
        !_uiForeground ||
        _stoppingByUser ||
        _manualDisconnectRequested ||
        !_autoRecoveryArmed) {
      return;
    }

    final status = await _refreshVpnStatus();
    if (!mounted ||
        !_uiForeground ||
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
      _setKeeperAction('resume-settle');
      await Future<void>.delayed(_resumeNetworkSettleDelay);
      if (!mounted ||
          !_uiForeground ||
          _stoppingByUser ||
          _manualDisconnectRequested ||
          !_autoRecoveryArmed) {
        return;
      }

      final settledStatus = await _refreshVpnStatus();
      if (!mounted ||
          !_uiForeground ||
          _stoppingByUser ||
          _manualDisconnectRequested ||
          !_autoRecoveryArmed) {
        return;
      }
      if (settledStatus == AurumVpnStatus.stopped) {
        _markUnexpectedStop('app-resume-after-settle');
        return;
      }

      _nextTunnelHealthCheckAt = DateTime.now();
      _setKeeperAction('resume-check');
      unawaited(_refreshTunnelHealth(source: 'app-resume'));
    }
  }

  Future<void> _load() async {
    final appInfo = await _loadAppInfo();
    final smartRouteRuDirect = await _store.loadSmartRouteRuDirect(
      installTime: widget.tvMode ? null : appInfo.installTime,
      updateTime: widget.tvMode ? null : appInfo.updateTime,
    );
    final distributionChannel = await _loadDistributionChannel();
    final storedProfiles = await _store.loadProfiles();
    final profiles = _clientSupportedProfiles(storedProfiles);
    final loadedStabilityStats = await _store.loadProfileStabilityStats();
    final loadedNetworkStabilityStats = await _store
        .loadProfileNetworkStabilityStats();
    final selectedId = await _store.loadSelectedProfileId();
    final autoSelection = await _store.loadAutomaticProfileSelection();
    final directLatencyAllowed = await _store.loadDirectLatencyAllowed();
    final language = _AppLanguage.fromCode(await _store.loadLanguageCode());
    final dnsProtectionMode = await _store.loadDnsProtectionMode();
    final storedManualDisconnectRequested = await _store
        .loadManualDisconnectRequested();
    final nativeManualDisconnectRequested =
        await _loadNativeManualDisconnectRequested();
    final manualDisconnectRequested =
        nativeManualDisconnectRequested ?? storedManualDisconnectRequested;
    if (nativeManualDisconnectRequested != null &&
        nativeManualDisconnectRequested != storedManualDisconnectRequested) {
      await _store.saveManualDisconnectRequested(manualDisconnectRequested);
    }
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
    final networkStabilityStats =
        <String, Map<String, ProfileNetworkStabilityStats>>{
          for (final entry in loadedNetworkStabilityStats.entries)
            if (profileIds.contains(entry.key))
              entry.key: Map<String, ProfileNetworkStabilityStats>.from(
                entry.value,
              ),
        };
    if (networkStabilityStats.length != loadedNetworkStabilityStats.length) {
      await _store.saveProfileNetworkStabilityStats(networkStabilityStats);
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
      _distributionChannel = distributionChannel;
      _profiles = profiles;
      _storedProfiles = storedProfiles;
      _profileStabilityStats = stabilityStats;
      _profileNetworkStabilityStats = networkStabilityStats;
      _selectedProfileId = resolvedSelectedId;
      _automaticProfileSelection = autoSelection ?? (selectedId == null);
      _directLatencyAllowed = directLatencyAllowed;
      _smartRouteRuDirect = smartRouteRuDirect;
      _smartRoutePreferenceLoaded = true;
      _dnsProtectionMode = dnsProtectionMode;
      _manualDisconnectRequested = manualDisconnectRequested;
      _message = profiles.isEmpty
          ? strings.addProfileHint
          : strings.loadedProfiles(profiles.length);
    });
    _soakProfilesLoaded = true;
    unawaited(_announceSoakBridgeReady());
    unawaited(_pingProfiles(profiles));
    unawaited(_resolveProfileCountries(profiles));
    unawaited(_refreshNetworkSnapshot('load'));
    unawaited(_reconcileRestoredVlessRuntime());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_showSubscriptionRenewalReminder(profiles));
        unawaited(_checkLatestUpdateNotice());
      }
    });
  }

  Future<void> _persistProfiles(List<VpnProfile> profiles) {
    _invalidateProfileProbes();
    final snapshot = List<VpnProfile>.unmodifiable(profiles);
    final saved = _profilePersistTail.catchError((_) {}).then((_) async {
      await _store.saveProfiles(snapshot);
      _storedProfiles = snapshot;
    });
    _profilePersistTail = saved;
    return saved;
  }

  Future<
    ({
      String version,
      String buildNumber,
      DateTime? installTime,
      DateTime? updateTime,
    })
  >
  _loadAppInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return (
        version: info.version.trim().isEmpty
            ? _appVersionFallback
            : info.version,
        buildNumber: info.buildNumber,
        installTime: info.installTime,
        updateTime: info.updateTime,
      );
    } on Object {
      return (
        version: _appVersionFallback,
        buildNumber: '',
        installTime: null,
        updateTime: null,
      );
    }
  }

  Future<AppDistributionChannel> _loadDistributionChannel() async {
    try {
      return await _updateService.distributionChannel();
    } on Object catch (error) {
      _queueLog(
        'Update distribution channel unavailable: '
        '${_redactSensitive('$error')}',
      );
      return AppDistributionChannel.unknown;
    }
  }

  Future<bool?> _loadNativeManualDisconnectRequested() async {
    try {
      return await _vpnEngine.getManualDisconnectRequested().timeout(
        _nativeShortTimeout,
      );
    } on Object catch (error) {
      _queueLog(
        'Native manual-disconnect state unavailable: '
        '${_redactSensitive('$error')}',
      );
      return null;
    }
  }

  Future<void> _reconcileRestoredVlessRuntime() async {
    if (_runtimeReconcileInFlight || _runtimeReconciled) {
      return;
    }
    _runtimeReconcileInFlight = true;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (!mounted || _manualDisconnectRequested || _stoppingByUser) {
        return;
      }

      final profile = _explicitSelectedProfile;
      if (profile == null ||
          (profile.kind != VpnProfileKind.vlessReality &&
              profile.kind != VpnProfileKind.vlessTls)) {
        return;
      }

      var status = await _vpnEngine.getVPNStatus().timeout(
        _nativeShortTimeout,
        onTimeout: () => _status,
      );
      if (status == AurumVpnStatus.starting) {
        status = await _waitForVpnStatus({
          AurumVpnStatus.started,
          AurumVpnStatus.stopped,
        }, timeout: const Duration(seconds: 8));
      }
      if (!mounted ||
          status != AurumVpnStatus.started ||
          _manualDisconnectRequested ||
          _stoppingByUser) {
        return;
      }

      final smartRouteBypassPackages = await _smartRouteBypassPackages();
      final expectedConfig = _buildRuntimeConfig(
        profile,
        plan: _connectionPlans(profile).first,
        smartRouteBypassPackages: smartRouteBypassPackages,
      );
      final currentConfig = await _vpnEngine.getConfig().timeout(
        _nativeConfigTimeout,
      );
      if (RuntimeConfigMatcher.equivalent(currentConfig, expectedConfig)) {
        _recordStabilityEvent('runtime-config-reconcile:matched');
        return;
      }

      _recordStabilityEvent('runtime-config-reconcile:mismatch');
      _queueLog(
        'Restored VPN runtime differs from the selected VLESS profile; '
        'restarting with the selected profile.',
      );
      final operation = _sessionController.beginProfileSwitch();
      await _runQueuedBusy(
        operation,
        () => _startVpnCore(profile, operation: operation, rapidRestart: true),
        message: s.switchingProfile,
      );
    } on VpnSessionCancelled catch (error) {
      _queueLog('Runtime config reconciliation superseded: $error');
    } on Object catch (error, stackTrace) {
      final errorText = _redactSensitive('$error');
      _recordStabilityEvent('runtime-config-reconcile:error:$errorText');
      _queueLog('Runtime config reconciliation failed: $errorText');
      _queueLog(_redactSensitive(stackTrace.toString().split('\n').first));
    } finally {
      _runtimeReconcileInFlight = false;
      _runtimeReconciled = true;
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
            if (status != AurumVpnStatus.started && status != _status) {
              _invalidateProfileProbes();
            }
            if (status == AurumVpnStatus.starting ||
                status == AurumVpnStatus.started) {
              KillSwitchHttpPolicy.cancelDirectRequests();
            }
            unawaited(_refreshKillSwitchState());
            if (_stoppingByUser && status == AurumVpnStatus.started) {
              _queueLog(
                'Native Started status ignored during stop transition.',
              );
              return;
            }
            _applyNetworkSnapshot(event, source: 'status-event');
            final now = DateTime.now();
            final nativeManualState = event['manualDisconnectRequested'];
            final nativeManualStop =
                nativeManualState == true &&
                (status == AurumVpnStatus.stopping ||
                    status == AurumVpnStatus.stopped);
            final nativeManualStart =
                nativeManualState == false &&
                !_userStopQueued &&
                (status == AurumVpnStatus.starting ||
                    status == AurumVpnStatus.started);
            final rawSessionReason = event['sessionReason'];
            final sessionReason = rawSessionReason is String
                ? rawSessionReason
                : null;
            final isNativeRecoveryStart =
                status == AurumVpnStatus.starting &&
                (sessionReason?.startsWith('watchdog:') == true ||
                    sessionReason?.startsWith('readiness:') == true ||
                    sessionReason == 'network-rebind');
            if (isNativeRecoveryStart) {
              _nativeRecoveryStarting = true;
            }
            final preserveRecoveryCounters =
                status == AurumVpnStatus.starting && _nativeRecoveryStarting;
            if (nativeManualStop || nativeManualStart) {
              unawaited(_store.saveManualDisconnectRequested(nativeManualStop));
            }
            var recoverUnexpectedStop = false;
            if (status == AurumVpnStatus.starting) {
              _trafficFlushTimer?.cancel();
              _trafficFlushTimer = null;
              _latestTrafficEvent = null;
            }
            setState(() {
              _status = status;
              if (status == AurumVpnStatus.starting) {
                _uplink = '0 B/s';
                _downlink = '0 B/s';
                _nativeUplinkSpeedBytes = 0;
                _nativeDownlinkSpeedBytes = 0;
                if (!preserveRecoveryCounters) {
                  _sessionTotal = '0 B';
                  _nativeSessionTotalBytes = 0;
                  _lastSessionTrafficBytes = 0;
                }
              }
              if (nativeManualStop) {
                _nativeRecoveryStarting = false;
                _manualDisconnectRequested = true;
                _autoRecoveryArmed = false;
                _lastError = null;
                _vpnUiCommandFailed = false;
                _lastRecoverySource = null;
                if (status == AurumVpnStatus.stopped) {
                  _connectedSince = null;
                  _lastTrafficAt = null;
                  _lastHealthyAt = null;
                  _lastIdleHealthCheckAt = null;
                  _lastNetworkEvent = 'manual-stop:native-action';
                  _message = s.vpnStopped;
                }
              } else if (nativeManualStart) {
                _manualDisconnectRequested = false;
                _lastError = null;
              }
              if (status == AurumVpnStatus.started) {
                _nativeRecoveryStarting = false;
                _clearRecoveredStopMessage();
                _lastError = null;
                if (!_busy &&
                    !_connectionQueueActive &&
                    _unconfirmedSwitchProfileId == null &&
                    !_stoppingByUser) {
                  _vpnUiCommandFailed = false;
                }
                if (_nativeOwnsTunnelHealth) {
                  _tunnelHealthFailures = 0;
                }
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
            if (status == AurumVpnStatus.started) {
              _dismissConnectionErrorSnack();
              final selected = _explicitSelectedProfile;
              if (selected != null && !_busy && !_connectionQueueActive) {
                unawaited(_pingProfile(selected));
              }
            }
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
          if (!mounted || _status == AurumVpnStatus.starting) {
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
              _applyNetworkSnapshot(latest, source: 'traffic-event');
              final uplinkSpeed = _eventInt(latest['uplinkSpeed']);
              final downlinkSpeed = _eventInt(latest['downlinkSpeed']);
              final sessionTotal = _eventInt(latest['sessionTotal']);
              final connectionsIn = _eventInt(latest['connectionsIn']);
              final connectionsOut = _eventInt(latest['connectionsOut']);
              final hasTraffic =
                  uplinkSpeed > 0 ||
                  downlinkSpeed > 0 ||
                  sessionTotal > _lastSessionTrafficBytes;
              final hasNativeActivity =
                  hasTraffic || connectionsIn > 0 || connectionsOut > 0;
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
                _nativeUplinkSpeedBytes = uplinkSpeed;
                _nativeDownlinkSpeedBytes = downlinkSpeed;
                _nativeSessionTotalBytes = sessionTotal;
                if (sessionTotal >= _lastSessionTrafficBytes) {
                  _lastSessionTrafficBytes = sessionTotal;
                }
                if (hasTraffic && _status == AurumVpnStatus.started) {
                  _lastTrafficAt = now;
                  _lastHealthyAt = now;
                  _tunnelHealthFailures = 0;
                }
                if (hasNativeActivity && _status == AurumVpnStatus.started) {
                  _lastNativeActivityAt = now;
                }
              }

              if (hasTraffic && _status == AurumVpnStatus.started) {
                _recordNetworkTrafficIfNeeded(sessionTotal, now);
              }
              if (_uiForeground && (displayChanged || healthChanged)) {
                setState(applyTrafficUpdate);
              } else {
                applyTrafficUpdate();
              }
              if (displayChanged) {
                unawaited(_syncConnectionNotification());
              }
              _publishSoakCounterIfDue(now);
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
      final nativeManualDisconnectRequested =
          await _loadNativeManualDisconnectRequested();
      if (nativeManualDisconnectRequested != null) {
        await _store.saveManualDisconnectRequested(
          nativeManualDisconnectRequested,
        );
        if (mounted) {
          setState(() {
            _manualDisconnectRequested = nativeManualDisconnectRequested;
            if (nativeManualDisconnectRequested) {
              _autoRecoveryArmed = false;
              _lastError = null;
            }
          });
        }
      }
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
          if (_status != status) _invalidateProfileProbes();
          _status = status;
          if (status == AurumVpnStatus.started) {
            _clearRecoveredStopMessage();
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
    _soakVpnInitialized = true;
    unawaited(_announceSoakBridgeReady());
  }

  Future<void> _announceSoakBridgeReady() async {
    if (_soakReadyAnnounced ||
        !_soakProfilesLoaded ||
        !_soakVpnInitialized ||
        _distributionChannel != AppDistributionChannel.soak) {
      return;
    }
    try {
      await _soakBridgeChannel
          .invokeMethod<void>('ready')
          .timeout(_nativeShortTimeout);
      _soakReadyAnnounced = true;
    } on Object {
      // The bridge exists only in the soak Android flavor.
    }
  }

  Future<String> _handleSoakBridgeCall(MethodCall call) async {
    if (call.method != 'execute' ||
        _distributionChannel != AppDistributionChannel.soak) {
      return jsonEncode(const {'ok': false, 'error': 'bridge_unavailable'});
    }

    final rawArguments = call.arguments;
    final arguments = rawArguments is Map
        ? rawArguments.map((key, value) => MapEntry('$key', value))
        : const <String, dynamic>{};
    final requestId = _sanitizeSoakRequestId(arguments['requestId']);
    final command = '${arguments['command'] ?? ''}'.trim().toLowerCase();

    try {
      switch (command) {
        case 'inventory':
          return jsonEncode({
            'ok': true,
            'requestId': requestId,
            'count': _storedProfiles.length,
            'profiles': [
              for (var index = 0; index < _storedProfiles.length; index += 1)
                _soakProfileDescriptor(index, _storedProfiles[index]),
            ],
          });
        case 'status':
          return jsonEncode({
            'ok': true,
            'requestId': requestId,
            ..._soakStatusPayload(),
          });
        case 'activate':
          return await _executeSoakActivate(
            requestId,
            '${arguments['profileToken'] ?? ''}',
          );
        case 'reconnect':
          return await _executeSoakReconnect(requestId);
        case 'stop':
          return await _executeSoakStop(requestId);
        case 'probe':
          final target = _soakProfileForToken(
            '${arguments['profileToken'] ?? ''}',
          );
          if (target == null) {
            return jsonEncode({
              'ok': false,
              'requestId': requestId,
              'error': 'invalid_profile_token',
            });
          }
          await _pingProfile(target.profile, force: true);
          return jsonEncode({
            'ok': true,
            'requestId': requestId,
            'profileToken': target.token,
            'latency': _profilePingLabel(target.profile),
            'probeState': _profileProbeResults[target.profile.id]?.state.name,
            'measurementPath': 'current_vpn_only',
          });
        default:
          return jsonEncode({
            'ok': false,
            'requestId': requestId,
            'error': 'unsupported_command',
          });
      }
    } on Object {
      return jsonEncode({
        'ok': false,
        'requestId': requestId,
        'error': 'internal_error',
      });
    }
  }

  Future<String> _executeSoakActivate(String requestId, String rawToken) async {
    final target = _soakProfileForToken(rawToken);
    if (target == null) {
      return jsonEncode({
        'ok': false,
        'requestId': requestId,
        'error': 'invalid_profile_token',
      });
    }
    final profile = target.profile;
    if (ProtocolTestMetadata.profile(profile)['offlineMarked'] == true) {
      return jsonEncode({
        'ok': false,
        'requestId': requestId,
        'profileToken': target.token,
        'error': 'offline_profile_skipped',
      });
    }
    if (_profileConnectBlockReason(profile) != null) {
      return jsonEncode({
        'ok': false,
        'requestId': requestId,
        'profileToken': target.token,
        'error': 'unsupported_profile',
      });
    }
    if (_busy || _connectionQueueActive) {
      return jsonEncode({
        'ok': false,
        'requestId': requestId,
        'profileToken': target.token,
        'error': 'busy',
      });
    }

    await _store.saveVpnDisclosureVersion(_vpnDisclosureVersion);
    // A failed connection intentionally leaves desiredRunning=true so the
    // regular recovery policy can observe the user's intent. The soak bridge
    // must still start the next profile when the native runtime is actually
    // stopped; otherwise one offline profile poisons the rest of the matrix.
    if (_connected) {
      await _selectProfile(profile);
    } else {
      await _selectProfile(profile);
      await _connect();
    }
    final status = await _refreshVpnStatus();
    final connected =
        status == AurumVpnStatus.started && _selectedProfileId == profile.id;
    return jsonEncode({
      'ok': connected,
      'requestId': requestId,
      'profileToken': target.token,
      if (!connected) 'error': 'connection_failed',
      ..._soakStatusPayload(),
    });
  }

  Future<String> _executeSoakReconnect(String requestId) async {
    final profile = _explicitSelectedProfile;
    if (profile == null || _profileConnectBlockReason(profile) != null) {
      return jsonEncode({
        'ok': false,
        'requestId': requestId,
        'error': 'no_runnable_profile',
      });
    }
    if (_busy || _connectionQueueActive) {
      return jsonEncode({'ok': false, 'requestId': requestId, 'error': 'busy'});
    }

    final operation = _sessionController.beginProfileSwitch();
    await _runQueuedBusy(
      operation,
      () => _startVpnCore(profile, operation: operation, rapidRestart: true),
      message: s.switchingProfile,
    );
    final status = await _refreshVpnStatus();
    final connected = status == AurumVpnStatus.started;
    return jsonEncode({
      'ok': connected,
      'requestId': requestId,
      if (!connected) 'error': 'reconnect_failed',
      ..._soakStatusPayload(),
    });
  }

  Future<String> _executeSoakStop(String requestId) async {
    if (_busy || _connectionQueueActive) {
      return jsonEncode({'ok': false, 'requestId': requestId, 'error': 'busy'});
    }
    await _disconnect();
    final status = await _refreshVpnStatus();
    final stopped = status == AurumVpnStatus.stopped;
    return jsonEncode({
      'ok': stopped,
      'requestId': requestId,
      if (!stopped) 'error': 'stop_failed',
      ..._soakStatusPayload(),
    });
  }

  Map<String, dynamic> _soakProfileDescriptor(int index, VpnProfile profile) {
    final selection = ProfileEngineSelector.select(profile);
    return {
      'profileToken': _soakTokenForIndex(index),
      'kind': profile.kind.name,
      'engine': selection.engine.name,
      'runnable': _profileConnectBlockReason(profile) == null,
      'latency': _profilePingLabel(profile),
      'latencyChecked': _profilePingCheckedAt.containsKey(profile.id),
      ...ProtocolTestMetadata.profile(profile),
    };
  }

  Map<String, dynamic> _soakStatusPayload() {
    final selectedIndex = _storedProfiles.indexWhere(
      (profile) => profile.id == _selectedProfileId,
    );
    final selectedProfile = selectedIndex >= 0
        ? _storedProfiles[selectedIndex]
        : null;
    final selection = selectedProfile == null
        ? null
        : ProfileEngineSelector.select(selectedProfile);
    return {
      'vpnStatus': _status,
      'connectionState': _effectiveConnectionStatus.name,
      'busy': _busy,
      'queueActive': _connectionQueueActive,
      'selectedProfileToken': selectedIndex < 0
          ? null
          : _soakTokenForIndex(selectedIndex),
      'kind': selectedProfile?.kind.name,
      'engine': selection?.engine.name,
      'networkType': _networkType,
      'trafficBytes': _lastSessionTrafficBytes,
      'nativeSessionTotalBytes': _nativeSessionTotalBytes,
      'nativeUplinkSpeedBytes': _nativeUplinkSpeedBytes,
      'nativeDownlinkSpeedBytes': _nativeDownlinkSpeedBytes,
      'sessionGeneration': _soakSessionGeneration,
      'uplink': _uplink,
      'downlink': _downlink,
      'sessionTotal': _sessionTotal,
      'errorCategory': ProtocolTestMetadata.failure([
        _lastError,
        _message,
        ..._logs.reversed.take(20),
      ]),
    };
  }

  void _publishSoakCounterIfDue(DateTime now) {
    if (_distributionChannel != AppDistributionChannel.soak ||
        _status != AurumVpnStatus.started) {
      return;
    }
    final selectedIndex = _storedProfiles.indexWhere(
      (profile) => profile.id == _selectedProfileId,
    );
    if (selectedIndex < 0) {
      return;
    }
    final attempt = _soakCounterPublishCadence.tryBegin(now);
    if (attempt == null) {
      return;
    }
    unawaited(_sendSoakCounter(_soakTokenForIndex(selectedIndex), attempt));
  }

  Future<void> _sendSoakCounter(String profileToken, int attempt) async {
    var succeeded = false;
    try {
      await _soakBridgeChannel
          .invokeMethod<void>('counter', {
            'profileToken': profileToken,
            'trafficBytes': _lastSessionTrafficBytes,
            'nativeSessionTotalBytes': _nativeSessionTotalBytes,
            'sessionGeneration': _soakSessionGeneration,
          })
          .timeout(_nativeShortTimeout);
      succeeded = true;
    } on Object {
      // Passive soak telemetry must never affect the production data path.
    } finally {
      _soakCounterPublishCadence.complete(
        attempt: attempt,
        succeeded: succeeded,
        at: DateTime.now(),
      );
    }
  }

  ({String token, VpnProfile profile})? _soakProfileForToken(String rawToken) {
    final token = rawToken.trim().toLowerCase();
    final match = RegExp(r'^p(\d{4})$').firstMatch(token);
    final ordinal = match == null ? null : int.tryParse(match.group(1)!);
    final index = ordinal == null ? -1 : ordinal - 1;
    if (index < 0 || index >= _storedProfiles.length) {
      return null;
    }
    return (token: _soakTokenForIndex(index), profile: _storedProfiles[index]);
  }

  String _soakTokenForIndex(int index) =>
      'p${(index + 1).toString().padLeft(4, '0')}';

  String _sanitizeSoakRequestId(Object? value) {
    final normalized = '$value'.trim();
    if (RegExp(r'^[a-zA-Z0-9._-]{1,64}$').hasMatch(normalized)) {
      return normalized;
    }
    return 'invalid';
  }

  void _handleEngineStreamError(
    String source,
    Object error, [
    StackTrace? stackTrace,
  ]) {
    final errorText = _redactSensitive('$error');
    _recordStabilityEvent('engine-stream-error:$source:$errorText');
    unawaited(OnDeviceDiagnosticsService.recordError('event_stream'));
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
    if (_nativeOwnsTunnelHealth && shouldProbeNow) {
      // Event delivery failure is not evidence that the native tunnel failed.
      _setKeeperAction('native-health-owner:engine-stream-$source');
      if (_uiForeground) {
        unawaited(_refreshVpnStatus());
      }
      return;
    }
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
      _notificationSyncPending = true;
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
      final state = _connectionUiState;
      final payload = state.toJson();
      // Never publish a cached direct measurement or a previous server's RTT.
      payload['pingMs'] = null;
      final selected = _explicitSelectedProfile;
      final checkedAt = _profilePingCheckedAt[selected?.id];
      final probe = _profileProbeResults[selected?.id];
      final age = checkedAt == null ? null : now.difference(checkedAt);
      if ((state.status == ConnectionStatus.connected ||
              state.status == ConnectionStatus.idle) &&
          !_busy &&
          !_connectionQueueActive &&
          !_stopProtectionCheck &&
          _unconfirmedSwitchProfileId == null &&
          age != null &&
          !age.isNegative &&
          age < const Duration(minutes: 1) &&
          probe != null &&
          probe.milliseconds != null &&
          probe.state == ServerProbeState.tunnelHealthy) {
        payload['pingMs'] = probe.milliseconds;
        payload['pingObservedAtMs'] = checkedAt!.millisecondsSinceEpoch;
      }
      await _bestEffortNative(
        'updateConnectionNotification',
        _vpnEngine.updateConnectionNotification(payload),
        timeout: const Duration(seconds: 2),
      );
    } finally {
      _notificationSyncInFlight = false;
      final shouldResync = _notificationSyncPending;
      _notificationSyncPending = false;
      if (shouldResync && mounted) {
        unawaited(_syncConnectionNotification(force: true));
      }
    }
  }

  Future<void> _refreshBatteryOptimizationStatus() async {
    if (!_powerManagerService.supported || _batteryOptimizationCheckInFlight) {
      return;
    }
    _batteryOptimizationCheckInFlight = true;
    try {
      final ignored = await _powerManagerService
          .isIgnoringBatteryOptimizations()
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
      if (mounted && _batteryOptimizationIgnored != ignored) {
        setState(() => _batteryOptimizationIgnored = ignored);
      }
    } finally {
      _batteryOptimizationCheckInFlight = false;
    }
  }

  Future<void> _openBackgroundPowerSettings() async {
    final opened = await _powerManagerService.openAppBatterySettings();
    if (mounted && !opened) _showSnack(s.batterySettingsFallback);
  }

  Future<void> _loadLocalIncidentState() async {
    if (!mounted || _localIncidentSettingsBusy) return;
    setState(() => _localIncidentSettingsBusy = true);
    try {
      final state = await _localIncidents.state();
      if (mounted && state != null) setState(() => _localIncidentState = state);
    } finally {
      if (mounted) setState(() => _localIncidentSettingsBusy = false);
    }
  }

  bool _hermesDeliverySettingsOpen = false;

  void _updateHermesLocalSettings({LocalIncidentState? state, bool? busy}) {
    if (!mounted) return;
    setState(() {
      if (state != null) _localIncidentState = state;
      if (busy != null) _localIncidentSettingsBusy = busy;
    });
  }

  Future<void> _showHermesPreview() async {
    if (!_localIncidents.hermesPreviewAvailable) return;
    final raw = await _localIncidents.hermesPreview();
    if (!mounted || _mobilePage != _MobilePage.settings) return;
    var example = s.hermesPreviewUnavailable;
    if (raw != null && utf8.encode(raw).length <= 1024) {
      try {
        final payload = jsonDecode(raw);
        if (payload is Map<String, Object?>) {
          example = const JsonEncoder.withIndent('  ').convert(payload);
        }
      } on FormatException {
        // A missing preview must not affect local consent or VPN.
      }
    }
    await showDialog<void>(
      context: context,
      builder: (context) => Theme(
        data: YurichTheme.mobile,
        child: AlertDialog(
          title: Text(s.hermesPreviewTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_hermesPreviewDescription),
                const SizedBox(height: 12),
                SelectableText(
                  example,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(s.close),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _changeLocalIncidentConsent(bool enabled) async {
    if (_localIncidentSettingsBusy || !_localIncidents.available) return;
    setState(() {
      _localIncidentSettingsBusy = true;
      // Do not queue anything while revocation is being persisted.
      if (!enabled) _localIncidentState = const LocalIncidentState.disabled();
    });
    try {
      if (enabled) {
        final consent = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(s.localIncidentTitle),
            content: SingleChildScrollView(child: Text(s.localIncidentConsent)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(s.localIncidentKeepOff),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(s.localIncidentEnable),
              ),
            ],
          ),
        );
        if (!mounted || consent != true) return;
      }
      final state = await _localIncidents.setEnabled(enabled);
      if (!mounted) return;
      if (state == null || state.enabled != enabled) {
        _showSnack(s.localIncidentSaveFailed);
      } else {
        setState(() => _localIncidentState = state);
      }
    } finally {
      if (mounted) setState(() => _localIncidentSettingsBusy = false);
    }
  }

  Future<void> _queueTerminalIncident(
    LocalConnectionIncidentAttempt attempt,
    VpnSessionOperation operation,
  ) async {
    final payload = attempt.takeTerminal(
      current:
          mounted &&
          !_localIncidentSettingsBusy &&
          _sessionController.isCurrent(operation),
      consentEpoch: _localIncidentState.epoch,
    );
    if (payload == null) return;
    final state = await _localIncidents.record(payload);
    if (mounted &&
        state != null &&
        !_localIncidentSettingsBusy &&
        _localIncidentState.epoch == attempt.epoch) {
      setState(() => _localIncidentState = state);
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
    if (_preparingAutoConnect) return;
    if (widget.tvMode) {
      final input = await showTvImportDialog(
        context,
        russian: _language == _AppLanguage.ru,
      );
      if (input != null && mounted) await _importText(input);
      return;
    }
    final action = await showDialog<_MobileImportAction>(
      context: context,
      builder: (context) => Theme(
        data: YurichTheme.mobile,
        child: _MobileImportDialog(
          controller: _manualController,
          strings: s,
          enabled: !_busy,
        ),
      ),
    );
    if (!mounted || _busy || _preparingAutoConnect) return;
    switch (action) {
      case _MobileImportAction.input:
        await _importManual();
      case _MobileImportAction.clipboard:
        await _importFromClipboard();
      case _MobileImportAction.qr:
        await _importFromQr();
      case null:
        break;
    }
  }

  Future<void> _importText(String text) async {
    // An immediate import must not look like restored settings during the
    // install check or be overwritten by the startup profile snapshot.
    await _initialSettingsLoad;
    if (!mounted) return;
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
      final merged = subscriptionSource == null
          ? _mergeProfiles(importedWithCachedData)
          : _subscriptionProfileReconciler
                .replaceRefreshedSources(
                  existing: _profiles,
                  imported: importedWithCachedData,
                  refreshedSources: {subscriptionSource},
                  selectedProfileId: importedWithCachedData.first.id,
                )
                .profiles;

      await _persistProfiles(merged);
      if (!widget.tvMode && _automaticProfileSelection) {
        // Do not let the first selected profile turn Auto into manual on reboot.
        await _store.saveAutomaticProfileSelection(true);
      }
      await _store.saveSelectedProfileId(importedWithCachedData.first.id);
      _manualController.clear();

      if (!mounted) {
        return;
      }
      setState(() {
        _profiles = merged;
        _selectedProfileId = importedWithCachedData.first.id;
        _cancelDirectLatency(clearReadings: true);
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
          final existing =
              existingById[profile.id] ??
              _subscriptionProfileReconciler.findLogicalMatch(
                profile,
                _profiles,
              );
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
    if (_busy || _subscriptionRefreshBusy || _preparingAutoConnect) {
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
      final refreshedSources = <String>{};
      Object? lastError;
      for (final source in sources) {
        try {
          final sourceProfiles = _clientSupportedProfiles(
            await _importer.importFromText(source),
          );
          imported.addAll(sourceProfiles);
          refreshedSources.add(source);
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
      final reconciliation = _subscriptionProfileReconciler
          .replaceRefreshedSources(
            existing: _profiles,
            imported: visibleImported,
            refreshedSources: refreshedSources,
            selectedProfileId: _selectedProfileId,
          );
      final merged = reconciliation.profiles;
      final selectedId = reconciliation.selectedProfileId;

      await _persistProfiles(merged);
      await _store.saveSelectedProfileId(selectedId);
      if (!mounted) {
        return;
      }

      setState(() {
        _profiles = merged;
        _cancelDirectLatency(clearReadings: true);
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
    if (_stopProtectionCheck || _userStopQueued) return;
    if (_preparingAutoConnect) {
      // Selection has not issued a native start; cancelling its generation is enough.
      _sessionController.beginDisconnect();
      _dismissConnectionErrorSnack();
      setState(() {
        _cancelAutoConnectPreparation();
        _message = s.vpnStopped;
      });
    } else if (_connected || _pendingNativeStart) {
      final pending = _pendingNativeStart;
      final generation = _sessionController.generation;
      setState(() => _stopProtectionCheck = true);
      try {
        await _refreshKillSwitchState();
        if (!mounted || _sessionController.generation != generation) return;
        if (_killSwitchState.known && _killSwitchState.alwaysOn) {
          await _openKillSwitchSettings();
          return;
        }
        await _disconnect(invalidatePendingStart: pending);
      } finally {
        if (mounted) setState(() => _stopProtectionCheck = false);
      }
    } else {
      await _connect(reportTerminalIncident: true);
    }
  }

  void _cancelAutoConnectPreparation() {
    if (!_preparingAutoConnect) return;
    _autoConnectPreparation = null;
    _cancelDirectLatency();
  }

  Future<void> _selectProfile(VpnProfile profile) async {
    _dismissConnectionErrorSnack();
    final vpnTransitionInFlight = _connectionQueueActive;
    if (_busy && !vpnTransitionInFlight) {
      return;
    }
    final wasAutomatic = !widget.tvMode && _automaticProfileSelection;
    final current = _explicitSelectedProfile;
    if (current?.id == profile.id &&
        !vpnTransitionInFlight &&
        !_preparingAutoConnect &&
        !wasAutomatic &&
        !_pendingNativeStart) {
      return;
    }

    final replacingPendingStart = _pendingNativeStart;
    final shouldKeepRunning = vpnTransitionInFlight
        ? _sessionController.desiredRunning
        : !_userStopQueued && (_connected || _canCancelVpnStart);

    final blockReason = _profileConnectBlockReason(profile);
    if (shouldKeepRunning && blockReason != null) {
      _queueLog(
        'Profile switch blocked for ${profile.kind.label}: $blockReason',
      );
      setState(() => _message = blockReason);
      _showSnack(blockReason);
      return;
    }

    if (!shouldKeepRunning) {
      setState(() {
        if (wasAutomatic) _automaticProfileSelection = false;
        _selectedProfileId = profile.id;
        _unconfirmedSwitchProfileId = null;
        _vpnUiCommandFailed = false;
        _message = blockReason ?? s.selectedProfile(profile.name);
      });
      if (!widget.tvMode) await _store.saveAutomaticProfileSelection(false);
      if (!mounted || _selectedProfileId != profile.id) return;
      await _store.saveSelectedProfileId(profile.id);
      unawaited(_pingProfile(profile, force: true));
      if (blockReason != null) {
        _showSnack(blockReason);
      }
      return;
    }

    final operation = _sessionController.beginProfileSwitch();
    final crossEngineRestart =
        replacingPendingStart ||
        current != null &&
            ProfileEngineSelector.select(current).engine !=
                ProfileEngineSelector.select(profile).engine;
    if (mounted) {
      setState(() {
        _cancelAutoConnectPreparation();
        if (wasAutomatic) _automaticProfileSelection = false;
        _selectedProfileId = profile.id;
        _unconfirmedSwitchProfileId = profile.id;
        _message = s.switchingProfile;
      });
    }
    await _runQueuedBusy(operation, () async {
      if (!widget.tvMode) await _store.saveAutomaticProfileSelection(false);
      _sessionController.ensureCurrent(operation);
      await _startVpnCore(
        profile,
        operation: operation,
        rapidRestart: true,
        crossEngineRestart: crossEngineRestart,
        invalidatePendingStart: replacingPendingStart,
      );
    }, message: s.switchingProfile);
  }

  Future<void> _connect({bool reportTerminalIncident = false}) async {
    final requestedGeneration = _sessionController.generation;
    if (!_smartRoutePreferenceLoaded ||
        _busy ||
        _connectionQueueActive ||
        _preparingAutoConnect ||
        !await _ensureVpnDisclosureConsent() ||
        !mounted ||
        requestedGeneration != _sessionController.generation ||
        _busy ||
        _connectionQueueActive ||
        _preparingAutoConnect) {
      return;
    }
    final automatic = !widget.tvMode && _automaticProfileSelection;
    if (automatic && _subscriptionRefreshBusy) {
      _showSnack(s.refreshingSubscriptions);
      return;
    }
    final operation = _sessionController.beginConnect();
    final candidates = automatic
        ? await _chooseAutomaticProfiles(operation)
        : null;
    if (!mounted ||
        !_sessionController.isCurrent(operation) ||
        _connected ||
        _connectionQueueActive) {
      return;
    }
    final profile = automatic
        ? candidates?.firstOrNull
        : (_explicitSelectedProfile ?? _autoConnectProfile());
    if (profile == null) {
      _sessionController.beginDisconnect();
      if (automatic && _profiles.isNotEmpty) {
        setState(() => _message = s.noAutoServer);
      }
      _showSnack(
        _profiles.isEmpty
            ? s.importFirst
            : automatic
            ? s.noAutoServer
            : s.autoConnectNoStableProfile,
      );
      return;
    }

    final blockReason = _profileConnectBlockReason(profile);
    if (blockReason != null) {
      _sessionController.beginDisconnect();
      _queueLog('Connection blocked for ${profile.kind.label}: $blockReason');
      setState(() {
        _lastError = blockReason;
        _vpnUiCommandFailed = true;
        _rememberVpnFailure(blockReason, 'connect');
        _message = blockReason;
      });
      _connectionErrorSnackBar = _showSnack(
        widget.tvMode
            ? blockReason
            : s.vpnFailureMessage(_lastVpnFailureCategory),
        duration: const Duration(seconds: 3),
      );
      return;
    }

    final incidentEpoch = _localIncidentState.epoch;
    final incident =
        reportTerminalIncident && !widget.tvMode && incidentEpoch != null
        ? LocalConnectionIncidentAttempt(incidentEpoch)
        : null;
    setState(() {
      _manualDisconnectRequested = false;
    });
    _autoRecoveryArmed = true;
    await _runQueuedBusy(
      operation,
      () async {
        await _store.saveManualDisconnectRequested(false);
        _sessionController.ensureCurrent(operation);
        try {
          if (automatic) {
            await _runAutomaticPass(
              operation,
              initialOrder: candidates!,
              measuredNetwork: _probePhysicalNetwork,
              incident: incident,
            );
          } else {
            await _startVpnCore(
              profile,
              operation: operation,
              incident: incident,
            );
          }
        } on VpnSessionCancelled {
          rethrow;
        } on Object catch (error) {
          _sessionController.ensureCurrent(operation);
          if (!automatic) {
            unawaited(
              _recordProfileStability(
                profile,
                (stats) => stats.recordStartFailure(_redactSensitive('$error')),
              ),
            );
            unawaited(
              _recordProfileNetworkStability(
                profile,
                (stats) => stats.recordHealthFailure(
                  'start:${_redactSensitive('$error')}',
                ),
              ),
            );
          }
          _autoRecoveryArmed = false;
          rethrow;
        }
      },
      message: automatic ? s.choosingAutoServer : s.connectingTo(profile.name),
      incident: incident,
    );
  }

  Future<_AutoPhysicalNetwork?> _readAutoPhysicalNetwork(
    VpnSessionOperation operation, {
    _AutoPhysicalNetwork? expected,
  }) async {
    _sessionController.ensureCurrent(operation);
    try {
      final snapshot = await _sessionController.cancelWhenSuperseded(
        operation,
        _vpnEngine.getNetworkSnapshot().timeout(_nativeShortTimeout),
      );
      _sessionController.ensureCurrent(operation);
      final key = snapshot['probePhysicalNetwork'];
      final type = _networkTypeFromSnapshot(snapshot);
      final confirmed = snapshot['autoPhysicalRouteConfirmed'] == true;
      final validatedKeys = snapshot['autoValidatedPhysicalKeys'];
      if (!confirmed &&
          expected != null &&
          validatedKeys is List &&
          validatedKeys.contains(expected.key)) {
        return (key: expected.key, type: expected.type, confirmed: false);
      }
      if (snapshot['validated'] != true ||
          key is! String ||
          key.isEmpty ||
          (type != 'wifi' && type != 'cellular' && type != 'ethernet')) {
        return null;
      }
      _applyNetworkSnapshot(snapshot, source: 'auto-network');
      return (key: key, type: type, confirmed: confirmed);
    } on VpnSessionCancelled {
      rethrow;
    } on Object {
      _sessionController.ensureCurrent(operation);
      return null;
    }
  }

  Future<void> _ensureAutoPhysicalNetwork(
    VpnSessionOperation operation,
    _AutoPhysicalNetwork expected,
  ) async {
    final first = await _readAutoPhysicalNetwork(operation, expected: expected);
    if (first?.key == expected.key) return;
    await _delayForOperation(const Duration(milliseconds: 350), operation);
    final second = await _readAutoPhysicalNetwork(
      operation,
      expected: expected,
    );
    if (second?.key != expected.key) throw const _AutoNetworkChanged();
  }

  Future<void> _runAutomaticPass(
    VpnSessionOperation operation, {
    required List<VpnProfile> initialOrder,
    required String? measuredNetwork,
    LocalConnectionIncidentAttempt? incident,
  }) async {
    final clock = Stopwatch()..start();
    final attemptedByPath = <String, Set<String>>{};
    _AutoPhysicalNetwork? lastPath;
    List<VpnProfile> ranked = const [];
    var waiting = false;
    while (clock.elapsed < _autoPassBudget) {
      _sessionController.ensureCurrent(operation);
      final path = await _readAutoPhysicalNetwork(operation);
      if (path == null) {
        waiting = true;
        incident?.nextCandidate();
        if (mounted && _message != s.autoWaitingForNetwork) {
          setState(() => _message = s.autoWaitingForNetwork);
        }
        await _delayForOperation(const Duration(seconds: 1), operation);
        continue;
      }
      if (path != lastPath || waiting) {
        // Wait for one more snapshot when the physical route changes. This
        // keeps a fleeting Wi-Fi/cellular edge from spending a server attempt.
        await _delayForOperation(const Duration(milliseconds: 350), operation);
        if (await _readAutoPhysicalNetwork(operation) != path) continue;
        ranked = path.key == measuredNetwork
            ? initialOrder
            : _rankAutomaticProfiles(_profiles, networkType: path.type);
        lastPath = path;
        waiting = false;
      }
      final attempted = attemptedByPath.putIfAbsent(path.key, () => <String>{});
      final candidate = ranked
          .where(
            (profile) =>
                !attempted.contains(profile.id) &&
                _profiles.any(
                  (current) => _sameAutomaticProfile(current, profile),
                ) &&
                _profileConnectBlockReason(profile) == null &&
                !ProtocolTestMetadata.isOfflineMarked(profile) &&
                !(profile.subscriptionExpiresAt?.isBefore(DateTime.now()) ??
                    false),
          )
          .firstOrNull;
      if (candidate == null) throw const _AutoPassExhausted();
      if (clock.elapsed >= _autoPassBudget) break;
      incident?.nextCandidate();
      if (mounted) {
        setState(() {
          _selectedProfileId = candidate.id;
          _unconfirmedSwitchProfileId = candidate.id;
          _message = s.autoTryingServer(attempted.length + 1, ranked.length);
        });
      }
      try {
        await _startVpnCore(
          candidate,
          operation: operation,
          incident: incident,
          autoNetwork: path,
        );
        return;
      } on _AutoNetworkChanged {
        incident?.nextCandidate();
        await _confirmAutoAttemptStopped(
          operation,
          invalidatePendingStart: true,
        );
        lastPath = null;
      } on _AutoCandidateUnavailable {
        _sessionController.ensureCurrent(operation);
        final current = await _readAutoPhysicalNetwork(operation);
        if (current?.key != path.key) {
          incident?.nextCandidate();
          lastPath = null;
          continue;
        }
        attempted.add(candidate.id);
        if (path.confirmed && current?.confirmed == true) {
          unawaited(
            _recordProfileNetworkStability(
              candidate,
              (stats) => stats.recordHealthFailure('auto-attempt-unavailable'),
              networkType: path.type,
            ).catchError((Object _) {}),
          );
        }
      }
    }
    if (waiting) throw const _AutoNetworkUnavailable();
    throw const _AutoPassExhausted();
  }

  bool _sameAutomaticProfile(VpnProfile current, VpnProfile planned) =>
      identical(current, planned) ||
      (current.id == planned.id &&
          current.kind == planned.kind &&
          current.originalInput == planned.originalInput &&
          current.server == planned.server &&
          current.port == planned.port &&
          current.rawConfig == planned.rawConfig &&
          current.subscriptionExpiresAt == planned.subscriptionExpiresAt &&
          jsonEncode(current.outbound) == jsonEncode(planned.outbound));

  Future<void> _confirmAutoAttemptStopped(
    VpnSessionOperation operation, {
    bool invalidatePendingStart = false,
  }) async {
    if (!await _stopVpnCore(
      updateMessage: false,
      operation: operation,
      invalidatePendingStart: invalidatePendingStart,
    )) {
      throw TimeoutException(s.vpnStopTimeout(_status));
    }
  }

  Future<bool> _ensureVpnDisclosureConsent() async {
    if (await _store.loadVpnDisclosureVersion() >= _vpnDisclosureVersion) {
      return true;
    }
    if (!mounted) {
      return false;
    }

    final isRussian = _language == _AppLanguage.ru;
    final smartRouteDisclosure = !_smartRouteRuDirect
        ? ''
        : isRussian
        ? 'При включённом Smart Route выбранные приложения и известные сервисы могут идти напрямую и видеть обычный IP сети. Это можно изменить в «Настройки → Smart Route». Kill Switch имеет приоритет.\n\n'
        : 'With Smart Route enabled, selected apps and known services can connect directly and see your regular network IP. You can change this in Settings → Smart Route. Kill Switch takes precedence.\n\n';
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          isRussian ? 'Защита трафика через VPN' : 'VPN traffic protection',
        ),
        content: SingleChildScrollView(
          child: Text(
            isRussian
                ? 'Yurich Connect использует системный Android VpnService, чтобы направлять трафик устройства через выбранный вами VPN-сервер и шифровать соединение до конечной точки туннеля.\n\n'
                      '$smartRouteDisclosure'
                      'Для маршрутизации и диагностики приложение локально обрабатывает DNS-запросы, адреса назначений, объём трафика и состояние соединения. Эти диагностические данные автоматически не отправляются разработчику и не используются для рекламы. Оператор выбранного VPN-сервера может обрабатывать сетевой трафик согласно своей политике.\n\n'
                      'Подключение не начнётся без вашего явного согласия.'
                : 'Yurich Connect uses Android VpnService to route device traffic through the VPN server you select and encrypt the connection to the tunnel endpoint.\n\n'
                      '$smartRouteDisclosure'
                      'For routing and diagnostics, the app locally processes DNS requests, destination addresses, traffic totals, and connection state. Diagnostic data is not automatically sent to the developer or used for advertising. The selected VPN server operator may process network traffic under its own policy.\n\n'
                      'The VPN will not connect without your explicit consent.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => unawaited(_openUrl(_privacyPolicyUrl)),
            child: Text(isRussian ? 'Политика' : 'Privacy'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(isRussian ? 'Отмена' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(isRussian ? 'Принимаю' : 'Accept'),
          ),
        ],
      ),
    );
    if (accepted != true) {
      return false;
    }
    await _store.saveVpnDisclosureVersion(_vpnDisclosureVersion);
    return true;
  }

  VpnProfile? _autoConnectProfile() {
    return _autoSelector.choose(
      _profiles,
      selectedProfileId: _selectedProfileId,
      pingMs: _profilePingMs,
      // A failed TLS diagnostic is not proof that a VPN protocol is offline.
      offlineProfileIds: {
        for (final profile in _profiles)
          if (ProtocolTestMetadata.profile(profile)['offlineMarked'] == true)
            profile.id,
      },
      stabilityStats: _profileStabilityStats,
    );
  }

  bool get _canMeasureDirectLatency =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      _uiForeground &&
      _status == AurumVpnStatus.stopped &&
      !_busy &&
      !_connectionQueueActive &&
      _killSwitchState.supported &&
      _killSwitchState.known &&
      !_killSwitchState.vpnActive &&
      !_smartRoutePausedByKillSwitch;

  void _cancelDirectLatency({bool clearReadings = false}) {
    _directLatencyProbe?.close();
    _directLatencyProbe = null;
    if (clearReadings) _directReadings.clear();
  }

  Future<bool> _confirmDirectLatency({bool fromSettings = false}) async {
    if (_directLatencyAllowed == true) return true;
    if (_directConsentVisible ||
        (!fromSettings && _directLatencyAllowed == false)) {
      return false;
    }
    _directConsentVisible = true;
    try {
      final choice = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(s.directLatencySetting),
          content: Text(s.directLatencyConsent),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(s.withoutDirectLatency),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(s.allowDirectLatency),
            ),
          ],
        ),
      );
      if (!mounted || choice == null) return false;
      final saved = await _saveDirectLatencyChoice(choice);
      if (!mounted) return false;
      setState(() => _directLatencyAllowed = saved && choice);
      return saved && choice;
    } finally {
      _directConsentVisible = false;
    }
  }

  Future<void> _changeDirectLatency(bool enabled) async {
    if (enabled) {
      await _confirmDirectLatency(fromSettings: true);
    } else {
      setState(() {
        _directLatencyAllowed = false;
        _cancelDirectLatency(clearReadings: true);
      });
      await _saveDirectLatencyChoice(false);
    }
  }

  Future<bool> _saveDirectLatencyChoice(bool enabled) async {
    try {
      if (await _store.saveDirectLatencyAllowed(enabled)) return true;
    } on Object {
      // No probe is allowed if consent persistence failed.
    }
    if (mounted) _showSnack(s.directLatencySaveFailed);
    return false;
  }

  Future<void> _chooseAutomaticMode() async {
    if (_preparingAutoConnect || _automaticProfileSelection) return;
    await _store.saveAutomaticProfileSelection(true);
    if (!mounted) return;
    setState(() {
      _automaticProfileSelection = true;
      _vpnUiCommandFailed = false;
      if (!_connected) _message = s.automaticServerHint;
    });
  }

  Future<Map<String, int>> _measureDirectLatency(
    List<VpnProfile> profiles, {
    required bool automatic,
  }) async {
    if (!_canMeasureDirectLatency ||
        _directLatencyAllowed != true ||
        _directLatencyProbe != null) {
      return const {};
    }
    final now = DateTime.now();
    final candidates = profiles
        .where(
          (profile) =>
              DirectLatencyProbe.eligible(profile) &&
              !ProtocolTestMetadata.isOfflineMarked(profile) &&
              !(profile.subscriptionExpiresAt?.isBefore(now) ?? false),
        )
        .take(automatic ? 48 : 64)
        .toList(growable: false);
    if (candidates.isEmpty) return const {};

    final probe = DirectLatencyProbe();
    final readings = <String, DirectLatencyReading>{};
    final generation = _sessionController.generation;
    bool current() =>
        mounted &&
        identical(_directLatencyProbe, probe) &&
        _sessionController.generation == generation &&
        _canMeasureDirectLatency &&
        _directLatencyAllowed == true;
    setState(() => _directLatencyProbe = probe);
    try {
      final network = await probe.network();
      if (network == null || !current()) return const {};
      final clock = Stopwatch()..start();
      final budget = automatic
          ? const Duration(seconds: 5)
          : const Duration(seconds: 12);
      var index = 0;
      Future<void> worker() async {
        while (current() &&
            clock.elapsed < budget &&
            index < candidates.length) {
          final profile = candidates[index++];
          final reading = await probe.check(
            profile,
            networkKey: network,
            stillAllowed: current,
          );
          if (current() && reading != null && clock.elapsed <= budget) {
            readings[profile.id] = reading;
          }
        }
      }

      await Future.wait(List.generate(8, (_) => worker())).timeout(
        budget,
        onTimeout: () {
          probe.close();
          return <void>[];
        },
      );
      final gate = DirectLatencyProbe();
      final stillOnNetwork = await gate.network() == network;
      gate.close();
      if (!current() || !stillOnNetwork) return const {};
      setState(() {
        if (_probePhysicalNetwork != network) _directReadings.clear();
        _probePhysicalNetwork = network;
        for (final profile in candidates) {
          final value = readings[profile.id];
          if (value == null) {
            _directReadings.remove(profile.id);
          } else {
            _directReadings[profile.id] = (
              reading: value,
              network: network,
              at: DateTime.now(),
            );
          }
        }
      });
      return readings.map((id, value) => MapEntry(id, value.milliseconds));
    } finally {
      probe.close();
      if (mounted && identical(_directLatencyProbe, probe)) {
        setState(() => _directLatencyProbe = null);
      }
    }
  }

  Future<List<VpnProfile>> _chooseAutomaticProfiles(
    VpnSessionOperation operation,
  ) async {
    setState(() {
      _autoConnectPreparation = operation;
      _message = s.choosingAutoServer;
      _vpnUiCommandFailed = false;
    });
    try {
      final originalProfiles = _profiles;
      final initial = _rankAutomaticProfiles(originalProfiles);
      final measurements =
          initial.isNotEmpty &&
              _canMeasureDirectLatency &&
              await _confirmDirectLatency() &&
              _sessionController.isCurrent(operation)
          ? await _measureDirectLatency(initial, automatic: true)
          : const <String, int>{};
      if (!mounted ||
          !_sessionController.isCurrent(operation) ||
          !_uiForeground ||
          !_automaticProfileSelection) {
        return const [];
      }
      final currentProfiles = _profiles;
      final currentMeasurements = identical(originalProfiles, currentProfiles)
          ? measurements
          : const <String, int>{};
      return _rankAutomaticProfiles(
        currentProfiles,
        measurements: currentMeasurements,
      );
    } finally {
      if (mounted && identical(_autoConnectPreparation, operation)) {
        setState(() => _autoConnectPreparation = null);
      }
    }
  }

  List<VpnProfile> _rankAutomaticProfiles(
    List<VpnProfile> profiles, {
    Map<String, int> measurements = const {},
    String? networkType,
  }) {
    final eligible = profiles
        .where((profile) => _profileConnectBlockReason(profile) == null)
        .toList(growable: false);
    return orderAutoFailoverCandidates(
      _autoSelector.rankForLatency(
        eligible,
        preferCurrentNetwork: true,
        directLatencyMs: measurements,
        offlineProfileIds: {
          for (final profile in eligible)
            if (ProtocolTestMetadata.isOfflineMarked(profile)) profile.id,
        },
        networkStats: {
          for (final profile in eligible)
            profile.id: _profileNetworkStabilityFor(
              profile.id,
              networkType: networkType,
            ),
        },
        lastProfileId: _selectedProfileId,
      ),
      locationOf: _profileCountryCode,
    );
  }

  ProfileStabilityStats _profileStabilityFor(String profileId) {
    return _profileStabilityStats[profileId] ?? const ProfileStabilityStats();
  }

  ProfileNetworkStabilityStats _profileNetworkStabilityFor(
    String profileId, {
    String? networkType,
  }) {
    final type = networkType ?? _networkType;
    return _profileNetworkStabilityStats[profileId]?[type] ??
        const ProfileNetworkStabilityStats();
  }

  Future<void> _recordProfileStability(
    VpnProfile profile,
    ProfileStabilityStats Function(ProfileStabilityStats current) update,
  ) async {
    final nextStats = Map<String, ProfileStabilityStats>.from(
      _profileStabilityStats,
    );
    nextStats[profile.id] = update(_profileStabilityFor(profile.id));
    if (mounted && _uiForeground) {
      setState(() => _profileStabilityStats = nextStats);
    } else {
      _profileStabilityStats = nextStats;
    }
    await _store.saveProfileStabilityStats(nextStats);
  }

  Future<void> _recordProfileNetworkStability(
    VpnProfile profile,
    ProfileNetworkStabilityStats Function(ProfileNetworkStabilityStats current)
    update, {
    String? networkType,
  }) async {
    final type = (networkType ?? _networkType).trim().isEmpty
        ? 'unknown'
        : (networkType ?? _networkType).trim().toLowerCase();
    final nextStats = <String, Map<String, ProfileNetworkStabilityStats>>{
      for (final entry in _profileNetworkStabilityStats.entries)
        entry.key: Map<String, ProfileNetworkStabilityStats>.from(entry.value),
    };
    final profileStats = nextStats.putIfAbsent(
      profile.id,
      () => <String, ProfileNetworkStabilityStats>{},
    );
    profileStats[type] = update(
      _profileNetworkStabilityFor(profile.id, networkType: type),
    );
    if (mounted && _uiForeground) {
      setState(() => _profileNetworkStabilityStats = nextStats);
    } else {
      _profileNetworkStabilityStats = nextStats;
    }
    await _store.saveProfileNetworkStabilityStats(nextStats);
  }

  bool _hasRecentNativeActivity(DateTime now) {
    final lastNativeAt = _lastNativeActivityAt;
    return lastNativeAt != null &&
        now.difference(lastNativeAt) < _nativeActivityGrace;
  }

  void _recordNetworkTrafficIfNeeded(int sessionTotal, DateTime now) {
    final profile = _selectedProfile;
    if (profile == null || sessionTotal <= 0) {
      return;
    }

    final delta = sessionTotal - _lastNetworkStatsTrafficBytes;
    final lastSavedAt = _lastNetworkStatsTrafficSavedAt;
    if (delta <= 0) {
      return;
    }

    final enoughBytes = delta >= _networkStatsTrafficMinDelta;
    final enoughTime =
        lastSavedAt == null ||
        now.difference(lastSavedAt) >= _networkStatsTrafficMinInterval;
    if (!enoughBytes && !enoughTime) {
      return;
    }

    _lastNetworkStatsTrafficBytes = sessionTotal;
    _lastNetworkStatsTrafficSavedAt = now;
    unawaited(
      _recordProfileNetworkStability(
        profile,
        (stats) => stats.recordTraffic(delta, at: now),
      ),
    );
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

  String _profileNetworkStatsSummary(VpnProfile profile) {
    final statsByNetwork = _profileNetworkStabilityStats[profile.id];
    if (statsByNetwork == null || statsByNetwork.isEmpty) {
      return 'none';
    }
    final entries = statsByNetwork.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries
        .map((entry) {
          final stats = entry.value;
          return '${entry.key}:starts=${stats.successfulStarts},'
              'recovery=${stats.recoveries},'
              'fail=${stats.healthFailures},'
              'traffic=${stats.trafficBytes}';
        })
        .join('; ');
  }

  Future<void> _startVpnCore(
    VpnProfile profile, {
    required VpnSessionOperation operation,
    bool rapidRestart = false,
    bool allowInProcessReload = true,
    bool crossEngineRestart = false,
    bool invalidatePendingStart = false,
    LocalConnectionIncidentAttempt? incident,
    _AutoPhysicalNetwork? autoNetwork,
  }) async {
    _sessionController.ensureCurrent(operation);
    final blockReason = _profileConnectBlockReason(profile);
    if (blockReason != null) {
      throw _ProfileConnectionBlocked(blockReason);
    }
    final engineSelection = ProfileEngineSelector.select(profile);
    final reconnectPolicy = VpnReconnectPolicy.resolve(
      kind: profile.kind,
      engine: engineSelection.engine,
      rapidRestart: rapidRestart,
      crossEngineRestart: crossEngineRestart,
      automaticFailover: autoNetwork != null,
    );

    _ignoreStoppedUntil = DateTime.now().add(const Duration(seconds: 18));
    final status = invalidatePendingStart
        ? AurumVpnStatus.stopping
        : await _refreshVpnStatus(
            operation: operation,
            allowCachedOnError: false,
          );
    var useInProcessReload =
        rapidRestart &&
        allowInProcessReload &&
        !crossEngineRestart &&
        !invalidatePendingStart &&
        status == AurumVpnStatus.started;
    if (invalidatePendingStart ||
        (status != AurumVpnStatus.stopped && !useInProcessReload)) {
      incident?.observedStart(
        profile,
        _networkChanging ? 'unknown' : _networkType,
      );
      final stopped = await _stopVpnCore(
        updateMessage: false,
        operation: operation,
        stopCallTimeout: reconnectPolicy.stopCallTimeout,
        stopStatusTimeout: reconnectPolicy.stopStatusTimeout,
        invalidatePendingStart: invalidatePendingStart,
      );
      if (!stopped) {
        incident?.signal = IncidentSignal.stopTimeout;
        throw TimeoutException(
          s.vpnStopTimeout(_status),
          reconnectPolicy.stopStatusTimeout,
        );
      }
    }

    await _delayForOperation(reconnectPolicy.startSettleDelay, operation);
    _sessionController.ensureCurrent(operation);

    _pendingLogs.clear();
    _logs.clear();
    _lastError = null;
    _connectedSince = null;
    _lastTrafficAt = null;
    _lastHealthyAt = null;
    _lastIdleHealthCheckAt = null;
    _lastRecoverySource = null;
    _lastNetworkEvent = 'manual-start';
    _nativeRecoveryStarting = false;
    _lastSessionTrafficBytes = 0;
    _nativeSessionTotalBytes = 0;
    _nativeUplinkSpeedBytes = 0;
    _nativeDownlinkSpeedBytes = 0;
    _soakSessionGeneration += 1;
    _soakCounterPublishCadence.reset();
    _lastNetworkStatsTrafficBytes = 0;
    _lastNetworkStatsTrafficSavedAt = null;
    _idleHealthChecks = 0;
    _idleRecoveryCount = 0;
    _tunnelHealthFailures = 0;
    await _bestEffortNative('clearLogs', _vpnEngine.clearLogs());
    _sessionController.ensureCurrent(operation);

    if (!reconnectPolicy.isRapid) {
      await _bestEffortNative(
        'requestNotificationPermission',
        _vpnEngine.requestNotificationPermission(),
      );
    }
    _sessionController.ensureCurrent(operation);

    Object? lastStartError;
    var connected = false;
    String? successfulPlanLabel;
    final plans = preferredFirst(
      _connectionPlans(profile),
      preferredKey: _lastSuccessfulPlanByProfileId[profile.id],
      keyOf: (plan) => plan.label,
    ).take(reconnectPolicy.maxPlans).toList(growable: false);
    final smartRouteBypassPackages = await _smartRouteBypassPackages();
    _sessionController.ensureCurrent(operation);
    final managedSmartRoute =
        _smartRouteRuDirect && SmartRouteAppsService.managedProfile(profile);
    final managedHermes =
        _localIncidents.hermesDeliveryAvailable &&
        !widget.tvMode &&
        profile.kind == VpnProfileKind.vlessXhttp &&
        profile.rawConfig == null &&
        engineSelection.engine == VpnCoreEngine.xray;
    Future<void> saveRuntimeConfig(
      String config,
      Duration timeout, {
      String label = 'saveConfig',
    }) async {
      _sessionController.ensureCurrent(operation);
      final saved = await _nativeCall(
        label,
        managedSmartRoute || managedHermes
            ? _smartRouteApps.saveManagedConfig(
                config,
                smartRouteApps: managedSmartRoute,
                hermesManagedXhttp: managedHermes,
              )
            : _vpnEngine.saveConfig(config),
        timeout: timeout,
      );
      _sessionController.ensureCurrent(operation);
      if (!saved) throw StateError(s.configSaveFailed);
    }

    for (
      var planIndex = 0;
      planIndex < plans.length && !connected;
      planIndex += 1
    ) {
      _sessionController.ensureCurrent(operation);
      incident?.signal = IncidentSignal.unknown;
      final attemptClock = Stopwatch()..start();
      final plan = plans[planIndex];
      final config = _buildRuntimeConfig(
        profile,
        plan: plan,
        smartRouteBypassPackages: smartRouteBypassPackages,
      );
      final configSummary = _summarizeSingBoxConfig(
        config,
        target: _vpnEngine.configTarget,
      );
      if (autoNetwork != null) {
        await _ensureAutoPhysicalNetwork(operation, autoNetwork);
      }
      final configTimeout = _reconnectPhaseTimeout(
        reconnectPolicy,
        attemptClock,
        reconnectPolicy.configTimeout,
      );
      await saveRuntimeConfig(config, configTimeout);

      for (
        var attempt = 1;
        attempt <= reconnectPolicy.maxAttemptsPerPlan && !connected;
        attempt += 1
      ) {
        _sessionController.ensureCurrent(operation);
        if (mounted) {
          setState(() {
            _selectedProfileId = profile.id;
            _lastError = null;
            if (autoNetwork == null) {
              _message = plans.length > 1
                  ? '${s.connectingStatus(profile.name)} · ${plan.label}'
                  : s.connectingStatus(profile.name);
            }
            _uplink = '0 B/s';
            _downlink = '0 B/s';
            _sessionTotal = '0 B';
            _lastConfigSummary = configSummary;
          });
        }

        final reloadInProcess = useInProcessReload;
        useInProcessReload = false;
        if (autoNetwork != null) {
          await _ensureAutoPhysicalNetwork(operation, autoNetwork);
        }
        final startTimeout = _reconnectPhaseTimeout(
          reconnectPolicy,
          attemptClock,
          reconnectPolicy.startCallTimeout,
        );
        incident?.observedStart(
          profile,
          _networkChanging ? 'unknown' : _networkType,
        );
        bool started;
        try {
          started = await _nativeCall(
            reloadInProcess ? 'reloadVPN' : 'startVPN',
            reloadInProcess ? _vpnEngine.reloadVPN() : _vpnEngine.startVPN(),
            timeout: startTimeout,
          );
          _sessionController.ensureCurrent(operation);
          if (!started) incident?.signal = IncidentSignal.startFailed;
        } on VpnSessionCancelled {
          rethrow;
        } on Object catch (error) {
          _sessionController.ensureCurrent(operation);
          incident?.observedStartError(error);
          if (autoNetwork != null) {
            // An Android permission/command error is not an unavailable
            // server. Do not rotate or keep re-prompting the user.
            if (error is! PlatformException ||
                (error.code != 'VPN_PERMISSION_DENIED' &&
                    error.code != 'VPN_PERMISSION_PENDING' &&
                    error.code != 'STOP_IN_PROGRESS' &&
                    error.code != 'START_CANCELLED')) {
              await _confirmAutoAttemptStopped(
                operation,
                invalidatePendingStart: true,
              );
            }
            rethrow;
          }
          started = false;
          lastStartError = _redactSensitive('$error');
        }
        if (started) {
          final finalStatus = await _waitForVpnStatus(
            {AurumVpnStatus.started},
            timeout: reconnectPolicy.timeoutWithinAttemptBudget(
              reconnectPolicy.statusTimeout,
              elapsed: attemptClock.elapsed,
            ),
            operation: operation,
            autoNetwork: autoNetwork,
          );
          if (finalStatus == AurumVpnStatus.started) {
            _sessionController.ensureCurrent(operation);
            final requiresSuccessfulProbe =
                !_nativeOwnsTunnelHealth &&
                ProfileEngineSelector.requiresSuccessfulStartupProbe(profile);
            if (!requiresSuccessfulProbe) {
              connected = true;
              successfulPlanLabel = plan.label;
              break;
            }

            final probeTimeout = reconnectPolicy.timeoutWithinAttemptBudget(
              reconnectPolicy.startupProbeTimeout,
              elapsed: attemptClock.elapsed,
            );
            final probePassed = await _probeLocalMixedProxy(
              attempts: 1,
              timeout: probeTimeout,
              operation: operation,
            );
            _sessionController.ensureCurrent(operation);
            if (probePassed) {
              connected = true;
              successfulPlanLabel = plan.label;
              break;
            } else {
              incident?.signal = IncidentSignal.trafficCheckFailed;
              lastStartError = s.vpnStartFailed;
              _queueLog(
                'Startup proxy probe failed for ${profile.kind.name}; '
                'restarting the tunnel before reporting Connected.',
              );
            }
          } else {
            incident?.signal = IncidentSignal.startTimeout;
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
          final stopped = await _stopVpnCore(
            updateMessage: false,
            operation: operation,
            stopCallTimeout: reconnectPolicy.stopCallTimeout,
            stopStatusTimeout: reconnectPolicy.stopStatusTimeout,
            // A start that did not become ready can still have a late native
            // command or recovery pending. Fence it even if status is Stopped.
            invalidatePendingStart: true,
          );
          if (!stopped) {
            incident?.signal = IncidentSignal.stopTimeout;
            throw TimeoutException(
              s.vpnStopTimeout(_status),
              reconnectPolicy.stopStatusTimeout,
            );
          }
          if (attempt < reconnectPolicy.maxAttemptsPerPlan) {
            await _delayForOperation(reconnectPolicy.retryDelay, operation);
            final retryConfigTimeout = _reconnectPhaseTimeout(
              reconnectPolicy,
              attemptClock,
              _nativeConfigTimeout,
            );
            // Saving through the unmanaged path clears the per-app binding.
            await saveRuntimeConfig(
              config,
              retryConfigTimeout,
              label: 'saveConfig retry',
            );
          }
          _ignoreStoppedUntil = DateTime.now().add(const Duration(seconds: 14));
        }
      }

      if (!connected && planIndex < plans.length - 1) {
        _queueLog('Naive mode fallback: ${plan.label} did not pass probe.');
        await _delayForOperation(reconnectPolicy.fallbackDelay, operation);
      }
    }

    if (!connected) {
      if (autoNetwork != null) throw const _AutoCandidateUnavailable();
      throw StateError('${lastStartError ?? s.vpnStartFailed}');
    }
    if (autoNetwork != null) {
      await _ensureAutoPhysicalNetwork(operation, autoNetwork);
    }
    // A later local preference write is not a connection failure.
    incident?.observedSuccess();
    if (successfulPlanLabel != null) {
      _lastSuccessfulPlanByProfileId[profile.id] = successfulPlanLabel;
    }

    _sessionController.ensureCurrent(operation);
    await _delayForOperation(
      reconnectPolicy.isRapid
          ? Duration.zero
          : const Duration(milliseconds: 250),
      operation,
    );
    _sessionController.ensureCurrent(operation);
    await _store.saveSelectedProfileId(profile.id);
    _sessionController.ensureCurrent(operation);
    if (mounted) {
      final connectedAt = DateTime.now();
      setState(() {
        _selectedProfileId = profile.id;
        _unconfirmedSwitchProfileId = null;
        _lastError = null;
        _vpnUiCommandFailed = false;
        _tunnelHealthFailures = 0;
        _autoRecoveryArmed = true;
        _connectedSince = connectedAt;
        _clockNow = connectedAt;
        _lastTrafficAt = connectedAt;
        _lastHealthyAt = connectedAt;
        _lastSessionTrafficBytes = 0;
        _nextTunnelHealthCheckAt = connectedAt.add(_tunnelHealthProbeInterval);
        _message = s.connectionProfile(profile.name);
      });
      unawaited(_syncConnectionNotification());
    }
    unawaited(
      _recordProfileStability(profile, (stats) => stats.recordStartSuccess()),
    );
    unawaited(
      _recordProfileNetworkStability(
        profile,
        (stats) => stats.recordStartSuccess(),
      ),
    );
    unawaited(_refreshConnectedCountry(profile.id, operation));
  }

  String? _profileConnectBlockReason(VpnProfile profile) {
    final selection = ProfileEngineSelector.select(profile);
    if (!selection.canRunInCurrentBuild) {
      return selection.reason;
    }
    if (!profile.kind.isClientSupported) {
      return s.unsupportedProtocol(profile.kind);
    }

    return TlsPinPolicy.profileError(profile);
  }

  Future<void> _disconnect({bool invalidatePendingStart = false}) async {
    final operation = _sessionController.beginDisconnect();
    _autoRecoveryArmed = false;
    setState(() {
      _manualDisconnectRequested = true;
      _message = s.disconnectingVpn;
    });
    await _runQueuedBusy(operation, () async {
      await _store.saveManualDisconnectRequested(true);
      _sessionController.ensureCurrent(operation);
      await _stopVpnCore(
        operation: operation,
        invalidatePendingStart: invalidatePendingStart,
      );
    }, message: s.disconnectingVpn);
  }

  Future<void> _enforceManualDisconnect(String source) async {
    if (!mounted || _stoppingByUser) {
      return;
    }
    if (!_sessionController.desiredRunning && _connectionQueueActive) {
      _queueLog('Manual disconnect guard already has a pending stop command.');
      return;
    }

    _queueLog(
      'Manual disconnect guard: native VPN reported Started from $source; '
      'stopping again.',
    );
    _autoRecoveryArmed = false;
    final operation = _sessionController.beginDisconnect();
    try {
      await _sessionController.enqueue(
        operation,
        () => _stopVpnCore(updateMessage: true, operation: operation),
      );
    } on VpnSessionCancelled catch (error) {
      _queueLog('Manual disconnect guard superseded: $error');
    }
  }

  Future<bool> _stopVpnCore({
    bool updateMessage = true,
    VpnSessionOperation? operation,
    Duration stopCallTimeout = const Duration(seconds: 5),
    Duration stopStatusTimeout = VpnReconnectPolicy.nativeStopStatusTimeout,
    bool invalidatePendingStart = false,
  }) async {
    if (operation != null) {
      _sessionController.ensureCurrent(operation);
    }
    _stoppingByUser = true;
    _ignoreStoppedUntil = DateTime.now().add(const Duration(seconds: 18));
    if (mounted) {
      setState(() => _lastError = null);
    }
    try {
      // A forced cancellation must send stop even before Android reports a
      // service. The authoritative status check follows the stop request.
      final status = invalidatePendingStart
          ? AurumVpnStatus.stopping
          : await _refreshVpnStatus(
              operation: operation,
              allowCachedOnError: false,
            );
      if (operation != null) {
        _sessionController.ensureCurrent(operation);
      }
      var nativeStopped = status == AurumVpnStatus.stopped;
      if (invalidatePendingStart || status != AurumVpnStatus.stopped) {
        try {
          await _vpnEngine.stopVPN().timeout(
            stopCallTimeout,
            onTimeout: () {
              _queueLog('Native call timeout [stopVPN]');
              return true;
            },
          );
        } on PlatformException catch (error) {
          if (error.code != 'STOP_VPN_ERROR') rethrow;
          // Native requested cleanup even if its acknowledgement failed.
          // Only the later authoritative Stopped result permits another start.
          _queueLog(
            'VPN stop acknowledgement failed; waiting for service exit',
          );
        }
        if (operation != null) {
          _sessionController.ensureCurrent(operation);
        }
        final stoppedStatus = await _waitForVpnStatus(
          {AurumVpnStatus.stopped},
          timeout: stopStatusTimeout,
          operation: operation,
        );
        nativeStopped = stoppedStatus == AurumVpnStatus.stopped;
        if (!nativeStopped) {
          _queueLog('VPN stop cleanup is still finishing: $stoppedStatus');
          if (mounted && updateMessage) {
            final error = s.vpnStopTimeout(stoppedStatus);
            setState(() {
              _lastError = error;
              _vpnUiCommandFailed = true;
              _rememberVpnFailure(error, 'disconnect');
              _message = error;
            });
          }
          return false;
        }
        // Stopped is emitted only after the native runtime has released the
        // active tunnel. A short guard is enough before saving the next config.
        if (operation != null) {
          await _delayForOperation(
            const Duration(milliseconds: 150),
            operation,
          );
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      }

      if (nativeStopped && mounted) {
        _ignoreStoppedUntil = DateTime.now().add(const Duration(seconds: 18));
        setState(() {
          _status = AurumVpnStatus.stopped;
          _uplink = '0 B/s';
          _downlink = '0 B/s';
          if (updateMessage) {
            _nativeRecoveryStarting = false;
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
            _vpnUiCommandFailed = false;
            _message = s.vpnStopped;
          }
        });
        unawaited(_syncConnectionNotification());
      }
      return nativeStopped;
    } finally {
      _stoppingByUser = false;
    }
  }

  Future<String> _refreshVpnStatus({
    VpnSessionOperation? operation,
    bool allowCachedOnError = true,
  }) async {
    if (operation != null) {
      _sessionController.ensureCurrent(operation);
    }
    try {
      final statusFuture = _nativeCall(
        'getVPNStatus',
        _vpnEngine.getVPNStatus(),
        timeout: _nativeShortTimeout,
      );
      final status = operation == null
          ? await statusFuture
          : await _sessionController.cancelWhenSuperseded(
              operation,
              statusFuture,
            );
      if (operation != null) {
        _sessionController.ensureCurrent(operation);
      }
      if (_stoppingByUser && status == AurumVpnStatus.started) {
        _queueLog(
          'Native getVPNStatus=Started ignored during stop transition.',
        );
        if (mounted && _status != AurumVpnStatus.stopping) {
          setState(() => _status = AurumVpnStatus.stopping);
        }
        return AurumVpnStatus.stopping;
      }
      if (mounted &&
          (_status != status ||
              (status == AurumVpnStatus.started &&
                  _lastRecoverySource != null))) {
        setState(() {
          if (_status != status) _invalidateProfileProbes();
          _status = status;
          if (status == AurumVpnStatus.started) {
            _clearRecoveredStopMessage();
          }
        });
      }
      return status;
    } on VpnSessionCancelled {
      rethrow;
    } on Object {
      return allowCachedOnError ? _status : AurumVpnStatus.stopping;
    }
  }

  Future<void> _refreshNetworkSnapshot(String source) async {
    try {
      final snapshot = await _nativeCall(
        'getNetworkSnapshot',
        _vpnEngine.getNetworkSnapshot(),
        timeout: _nativeShortTimeout,
      );
      _applyNetworkSnapshot(snapshot, source: source);
    } on Object catch (error) {
      _queueLog(
        'Native network snapshot ignored [$source]: ${_redactSensitive('$error')}',
      );
    }
  }

  Future<String> _waitForVpnStatus(
    Set<String> expected, {
    required Duration timeout,
    VpnSessionOperation? operation,
    _AutoPhysicalNetwork? autoNetwork,
  }) async {
    if (operation != null) {
      _sessionController.ensureCurrent(operation);
    }
    final deadline = DateTime.now().add(timeout);
    final routeClock = Stopwatch()..start();
    var nextRouteCheck = Duration.zero;
    var latest = _status;
    while (DateTime.now().isBefore(deadline)) {
      if (autoNetwork != null &&
          operation != null &&
          routeClock.elapsed >= nextRouteCheck) {
        await _ensureAutoPhysicalNetwork(operation, autoNetwork);
        nextRouteCheck = routeClock.elapsed + const Duration(seconds: 1);
      }
      latest = await _refreshVpnStatus(
        operation: operation,
        allowCachedOnError: operation == null,
      );
      if (expected.contains(latest)) {
        return latest;
      }
      if (operation == null) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      } else {
        await _delayForOperation(const Duration(milliseconds: 300), operation);
      }
    }
    return latest;
  }

  Future<void> _delayForOperation(
    Duration duration,
    VpnSessionOperation operation,
  ) {
    _sessionController.ensureCurrent(operation);
    if (duration <= Duration.zero) {
      return Future<void>.value();
    }
    return _sessionController.cancelWhenSuperseded(
      operation,
      Future<void>.delayed(duration),
    );
  }

  Duration _reconnectPhaseTimeout(
    VpnReconnectPolicy policy,
    Stopwatch attemptClock,
    Duration preferred,
  ) {
    final timeout = policy.timeoutWithinAttemptBudget(
      preferred,
      elapsed: attemptClock.elapsed,
    );
    if (timeout <= Duration.zero) {
      throw TimeoutException(
        'VPN reconnect attempt budget expired.',
        policy.attemptBudget,
      );
    }
    return timeout;
  }

  Future<void> _refreshStatusWatchdog() async {
    if (!mounted ||
        !_uiForeground ||
        _busy ||
        _statusWatchdogInFlight ||
        _manualDisconnectRequested ||
        _connectionQueueActive) {
      return;
    }

    _statusWatchdogInFlight = true;
    try {
      await _refreshNetworkSnapshot('watchdog');
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
        if (_isNetworkChanging(now)) {
          _setKeeperAction('watchdog-network-changing');
          return;
        }
        if (_isResumeRecoveryQuietWindow(now)) {
          _setKeeperAction('watchdog-resume-quiet');
          return;
        }
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

  void _clearRecoveredStopMessage() {
    if (_lastRecoverySource == null ||
        _manualDisconnectRequested ||
        _stoppingByUser) {
      return;
    }
    final profile = _selectedProfile;
    _message = profile == null
        ? s.connected
        : s.connectionProfile(profile.name);
    _lastError = null;
    _lastRecoverySource = null;
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
      unawaited(
        _recordProfileNetworkStability(
          profile,
          (stats) => stats.recordHealthFailure('unexpected-stop:$source'),
        ),
      );
    }
    setState(() {
      _lastError = s.vpnStoppedUnexpectedly;
      _lastRecoverySource = source;
      _rememberVpnFailure('unexpected-stop', 'runtime');
      _message = profile == null
          ? s.openLogsMessage
          : '${s.vpnStoppedUnexpectedly}. ${s.connectingStatus(profile.name)}';
    });
    _setKeeperAction('native-recovery:$source');
    _queueLog(
      'VPN watchdog: native service owns recovery; Flutter restart skipped.',
    );
  }

  Future<void> _refreshTunnelHealth({String source = 'watchdog'}) async {
    if (_tunnelHealthCheckInFlight ||
        _manualDisconnectRequested ||
        _connectionQueueActive ||
        !mounted) {
      return;
    }

    final profile = _selectedProfile;
    if (profile == null) {
      return;
    }

    final now = DateTime.now();
    if (_nativeOwnsTunnelHealth) {
      _setKeeperAction('native-health-owner:$source');
      return;
    }
    if (_isNetworkChanging(now)) {
      _setKeeperAction('health-skip-network-changing:$source');
      _nextTunnelHealthCheckAt =
          _networkChangingUntil ?? now.add(_networkChangingSettleWindow);
      return;
    }

    final nextCheckAt = _nextTunnelHealthCheckAt;
    if (nextCheckAt != null && now.isBefore(nextCheckAt)) {
      return;
    }

    if (_hasRecentNativeActivity(now)) {
      _tunnelHealthFailures = 0;
      _lastHealthyAt = _lastNativeActivityAt ?? now;
      _setKeeperAction('native-activity-ok:$source', at: _lastHealthyAt);
      _nextTunnelHealthCheckAt = now.add(_healthProbeIntervalFor(source));
      unawaited(
        _recordProfileStability(
          profile,
          (stats) => stats.recordHealthy(at: _lastHealthyAt),
        ),
      );
      unawaited(
        _recordProfileNetworkStability(
          profile,
          (stats) => stats.recordHealthy(at: _lastHealthyAt),
        ),
      );
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
      unawaited(
        _recordProfileNetworkStability(
          profile,
          (stats) => stats.recordHealthy(at: lastTrafficAt),
        ),
      );
      return;
    }

    if (!ProfileEngineSelector.supportsLocalProxyProbe(profile)) {
      _tunnelHealthFailures = 0;
      _lastHealthyAt = now;
      _setKeeperAction('native-status-ok:$source', at: now);
      _nextTunnelHealthCheckAt = now.add(_healthProbeIntervalFor(source));
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
        unawaited(
          _recordProfileNetworkStability(
            profile,
            (stats) => stats.recordHealthy(),
          ),
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
      unawaited(
        _recordProfileNetworkStability(
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
        _queueLog(
          'VPN watchdog: tunnel is unhealthy for ${profile.name}; '
          'native service remains the only recovery owner.',
        );
        if (mounted) {
          setState(() {
            _lastError = s.vpnStoppedUnexpectedly;
            _message = s.openLogsMessage;
          });
        }
        _setKeeperAction('degraded:health-probe');
      }
    } finally {
      _tunnelHealthCheckInFlight = false;
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

  String _buildRuntimeConfig(
    VpnProfile profile, {
    required _ConnectionConfigPlan plan,
    required List<String> smartRouteBypassPackages,
  }) {
    final engine = ProfileEngineSelector.select(profile);
    if (engine.engine == VpnCoreEngine.xray) {
      if (!engine.canRunInCurrentBuild) {
        throw UnsupportedError(engine.reason);
      }
      return _xrayConfigBuilder.build(
        profile,
        smartRouteRuDirect: _smartRouteRuDirect,
        smartRouteRuBypassPackages: smartRouteBypassPackages,
        dnsProtectionMode: _dnsProtectionMode,
      );
    }

    return _configBuilder.build(
      profile,
      naiveMode: plan.naiveMode,
      smartRouteRuDirect: _smartRouteRuDirect,
      smartRouteRuBypassPackages: smartRouteBypassPackages,
      dnsProtectionMode: _dnsProtectionMode,
    );
  }

  Future<bool> _probeLocalMixedProxy({
    int attempts = 2,
    bool logFailures = true,
    Duration? timeout,
    VpnSessionOperation? operation,
  }) async {
    final probe = LocalProxyHealthProbe(
      proxyPort: SingBoxConfigBuilder.localMixedProxyPort,
      userAgent: 'YurichConnect/$_appVersion',
      onFailure: logFailures
          ? (message) => _queueLog(_redactSensitive(message))
          : null,
    );

    try {
      for (var attempt = 1; attempt <= attempts; attempt += 1) {
        if (operation != null) _sessionController.ensureCurrent(operation);
        final check = probe.check(timeout: timeout);
        final healthy = operation == null
            ? await check
            : await _sessionController.cancelWhenSuperseded(operation, check);
        if (healthy) return true;

        if (attempt < attempts) {
          if (operation == null) {
            await Future<void>.delayed(const Duration(milliseconds: 700));
          } else {
            await _delayForOperation(
              const Duration(milliseconds: 700),
              operation,
            );
          }
        }
      }
      return false;
    } finally {
      probe.close();
    }
  }

  Future<void> _pingProfiles(
    List<VpnProfile> profiles, {
    bool force = false,
  }) async {
    if (_pingAllInFlight || profiles.isEmpty) {
      return;
    }
    if (_status != AurumVpnStatus.started || _busy || _connectionQueueActive) {
      if (force) {
        _showSnack(
          _language == _AppLanguage.ru
              ? 'Для проверки нужен работающий VPN.'
              : 'Connect to a working VPN first.',
        );
      }
      return;
    }
    if (_connected && !force) {
      final selectedProfile = _explicitSelectedProfile;
      if (selectedProfile == null ||
          !profiles.any((profile) => profile.id == selectedProfile.id)) {
        return;
      }

      _pingAllInFlight = true;
      try {
        await _pingProfile(selectedProfile, force: true);
      } finally {
        _pingAllInFlight = false;
      }
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

    final epoch = _profileProbeEpoch;
    _pingAllInFlight = true;
    try {
      for (final batch in fixedSizeBatches(orderedProfiles, size: 4)) {
        if (!mounted || epoch != _profileProbeEpoch) {
          return;
        }
        await Future.wait(
          batch.map((profile) => _pingProfile(profile, force: force)),
        );
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    } finally {
      _pingAllInFlight = false;
    }
  }

  void _invalidateProfileProbes() {
    _cancelDirectLatency();
    _profileProbeEpoch += 1;
    for (final cancel in _activeProfileProbeCancels.toList(growable: false)) {
      cancel();
    }
    _activeProfileProbeCancels.clear();
    _profilePingMs.clear();
    _profileProbeResults.clear();
    _profilePingCheckedAt.clear();
    _profilePingBusy.clear();
  }

  Future<void> _pingProfile(VpnProfile profile, {bool force = false}) async {
    if (!mounted || _profilePingBusy[profile.id] == true) return;
    if (_status != AurumVpnStatus.started || _busy || _connectionQueueActive) {
      return;
    }
    // Custom runtime routes cannot attest that the loopback inbound is proxied.
    if (_explicitSelectedProfile?.kind.isClientSupported != true ||
        _selectedProfileId == _unconfirmedSwitchProfileId) {
      return;
    }
    final checkedAt = _profilePingCheckedAt[profile.id];
    final previous = _profileProbeResults[profile.id];
    final cacheTtl = previous?.milliseconds != null
        ? _profilePingCacheTtl
        : const Duration(seconds: 30);
    if (!force &&
        checkedAt != null &&
        DateTime.now().difference(checkedAt) < cacheTtl) {
      return;
    }
    final epoch = _profileProbeEpoch;
    final generation = _sessionController.generation;
    final selectedId = _selectedProfileId;
    bool current() =>
        mounted &&
        epoch == _profileProbeEpoch &&
        generation == _sessionController.generation &&
        selectedId == _selectedProfileId &&
        _status == AurumVpnStatus.started;
    setState(() => _profilePingBusy[profile.id] = true);
    final stopwatch = Stopwatch()..start();
    final probe = ProxyServerProbe(
      proxyPort: SingBoxConfigBuilder.localMixedProxyPort,
    );
    final health = LocalProxyHealthProbe(
      proxyPort: SingBoxConfigBuilder.localMixedProxyPort,
      userAgent: 'YurichConnect/ServerCheck',
    );
    void cancel() {
      probe.close();
      health.close();
    }

    _activeProfileProbeCancels.add(cancel);
    try {
      ServerProbeResult result;
      if (ProtocolTestMetadata.profile(profile)['offlineMarked'] == true) {
        result = const ServerProbeResult(ServerProbeState.offlineMarked);
      } else if (profile.id == selectedId) {
        // Measure a real HTTPS request through the active tunnel. A separate
        // TLS handshake to the VPN endpoint is not a test of this tunnel.
        final healthy = await health.check(timeout: const Duration(seconds: 8));
        result = healthy
            ? ServerProbeResult(
                ServerProbeState.tunnelHealthy,
                stopwatch.elapsedMilliseconds.clamp(1, 8000),
              )
            : const ServerProbeResult(ServerProbeState.noResponse);
      } else if (ServerProbeTarget.usesUdp(profile)) {
        result = const ServerProbeResult(ServerProbeState.needsConnection);
      } else {
        final target = ServerProbeTarget.fromProfile(profile);
        result = target == null
            ? const ServerProbeResult(ServerProbeState.unsupported)
            : await probe.check(target);
      }
      if (!current() || result.state == ServerProbeState.cancelled) return;
      setState(() {
        _profileProbeResults[profile.id] = result;
        _profilePingCheckedAt[profile.id] = DateTime.now();
        _profilePingMs.remove(profile.id);
        final milliseconds = result.milliseconds;
        if (milliseconds != null) _profilePingMs[profile.id] = milliseconds;
      });
      if (profile.id == _selectedProfileId) {
        unawaited(_syncConnectionNotification());
      }
    } finally {
      cancel();
      _activeProfileProbeCancels.remove(cancel);
      if (current()) {
        setState(() => _profilePingBusy[profile.id] = false);
      }
    }
  }

  String _profilePingLabel(VpnProfile profile) {
    if (_profilePingBusy[profile.id] == true) {
      return '...';
    }
    if (ProtocolTestMetadata.profile(profile)['offlineMarked'] == true) {
      return 'offline';
    }
    if (_status != AurumVpnStatus.started) {
      return const ServerProbeResult(
        ServerProbeState.needsVpn,
      ).label(russian: _language == _AppLanguage.ru);
    }
    return (_profileProbeResults[profile.id] ??
            const ServerProbeResult(ServerProbeState.cancelled))
        .label(russian: _language == _AppLanguage.ru);
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
        if (ProfileCountryResolver.hasDeclaredCountry(profile) ||
            ProfileGeo.countryCodeToFlag(profile.countryCode) != null) {
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

  Future<void> _refreshConnectedCountry(
    String profileId,
    VpnSessionOperation operation,
  ) async {
    bool isCurrent() =>
        mounted &&
        _status == AurumVpnStatus.started &&
        _selectedProfileId == profileId &&
        _sessionController.isCurrent(operation);
    final index = _profiles.indexWhere((profile) => profile.id == profileId);
    if (index < 0 ||
        ProfileCountryResolver.hasDeclaredCountry(_profiles[index])) {
      return;
    }
    final source = _profiles[index].originalInput;
    final cancellation = ProfileGeoCancellation();
    try {
      await _delayForOperation(const Duration(milliseconds: 1400), operation);
      if (!isCurrent()) return;
      final geo = await _sessionController.cancelWhenSuperseded(
        operation,
        _geoService.resolveExitCountryThroughTunnel(cancellation: cancellation),
      );
      if (!isCurrent() || geo == null) return;
      final current = _profiles.indexWhere(
        (profile) => profile.id == profileId,
      );
      if (current < 0 || _profiles[current].originalInput != source) return;
      await _saveProfileCountry(profileId, geo);
      _queueLog('Geo: exit country ${geo.countryCode}');
    } on VpnSessionCancelled {
      // A different profile owns the tunnel now; close only this lookup.
    } finally {
      cancellation.cancel();
    }
  }

  Future<void> _saveProfileCountry(String profileId, ProfileGeo geo) async {
    if (!mounted) return;
    final index = _profiles.indexWhere((profile) => profile.id == profileId);
    if (index < 0) {
      return;
    }

    final current = _profiles[index];
    if (ProfileCountryResolver.hasDeclaredCountry(current)) return;
    final countryName = ProfileCountryResolver.countryNameForGeo(geo);
    if (current.countryCode == geo.countryCode &&
        current.countryName == countryName) {
      return;
    }

    final next = [..._profiles];
    next[index] = current.copyWith(
      countryCode: geo.countryCode,
      countryName: countryName,
    );
    setState(() {
      _profiles = next;
    });
    try {
      await _persistProfiles(next);
    } on Object catch (error) {
      // Cosmetic metadata must not fail an otherwise healthy VPN session.
      _queueLog('Geo: metadata persistence unavailable (${error.runtimeType})');
    }
    if (!mounted) return;
    if (profileId == _selectedProfileId) {
      unawaited(_syncConnectionNotification());
    }
  }

  String? _profileCountryFlag(VpnProfile profile) {
    return ProfileCountryResolver.displayCountryFlag(profile);
  }

  String _profileDisplayName(VpnProfile profile) {
    final trimmed = profile.name.trimLeft();
    if (_leadingFlag(trimmed) != null) {
      return String.fromCharCodes(trimmed.runes.skip(2)).trimLeft();
    }
    return profile.name;
  }

  String? _leadingFlag(String value) {
    return ProfileCountryResolver.leadingFlag(value);
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
    // The persisted decision must finish loading before the first edit. A
    // slow boot must not apply its stale snapshot over a user's new choice.
    if (!_smartRoutePreferenceLoaded) return;
    if (_smartRoutePausedByKillSwitch) {
      _showSnack(
        _language == _AppLanguage.ru
            ? 'Smart Route приостановлен строгим kill switch. Настройка сохранена.'
            : 'Strict kill switch suspends Smart Route. Your preference is preserved.',
      );
      return;
    }
    if (_smartRouteRuDirect == enabled ||
        _busy ||
        _connectionQueueActive ||
        _smartRouteSettingsBusy) {
      return;
    }

    final profile = _selectedProfile;
    Future<void> persist() async {
      // Revoke the association even when no TUN is running: a native
      // background restore must not reuse a previously enabled config.
      if (!enabled) await _smartRouteApps.clearBinding();
      await _store.saveSmartRouteRuDirect(enabled);
      if (!mounted) return;
      setState(() {
        _smartRouteRuDirect = enabled;
        _message = enabled ? s.smartRouteEnabled : s.smartRouteDisabled;
      });
    }

    if (!_connected ||
        profile == null ||
        !SmartRouteAppsService.managedProfile(profile)) {
      await _runBusy(persist, message: s.smartRouteApplying);
      return;
    }

    final operation = _sessionController.beginProfileSwitch();
    await _runQueuedBusy(operation, () async {
      // Do not commit "off" while a TUN with the old exclusions still exists.
      if (!enabled &&
          !await _stopVpnCore(updateMessage: false, operation: operation)) {
        throw StateError(s.vpnStopTimeout(_status));
      }
      await persist();
      _sessionController.ensureCurrent(operation);
      await _startVpnCore(profile, operation: operation, rapidRestart: true);
    }, message: s.smartRouteApplying);
  }

  Future<void> _editSmartRouteApps() async {
    if (!_smartRoutePreferenceLoaded ||
        _smartRouteSettingsBusy ||
        _busy ||
        _connectionQueueActive) {
      return;
    }
    _smartRouteSettingsBusy = true;
    try {
      final snapshot = await _smartRouteApps.read();
      if (!mounted) return;
      final ru = _language == _AppLanguage.ru;
      if (snapshot.candidates.isEmpty) {
        _showSnack(
          ru ? 'Список приложений недоступен.' : 'App choices are unavailable.',
        );
        return;
      }
      final currentProfile = _selectedProfile;
      final builtIn = SmartRouteRules.ruBypassPackages(const []).toSet();
      final selection = await showDialog<Set<String>>(
        context: context,
        builder: (_) => SmartRouteAppsDialog(
          snapshot: snapshot,
          builtInPackages: builtIn,
          smartRouteEnabled: _smartRouteRuDirect,
          managedProfile:
              currentProfile != null &&
              SmartRouteAppsService.managedProfile(currentProfile),
          vpnActive: _status == AurumVpnStatus.started,
          russian: ru,
        ),
      );
      if (!mounted || selection == null || _busy || _connectionQueueActive) {
        return;
      }
      final previousChoices = snapshot.selected.difference(builtIn);
      if (setEquals(previousChoices, selection)) return;
      final profile = _selectedProfile;
      final protect = await _killSwitchService.read();
      if (!mounted || _busy || _connectionQueueActive) return;
      bool canApplyAppRoutes(KillSwitchState state) =>
          state.supported &&
          state.known &&
          !state.requested &&
          !state.alwaysOn &&
          !state.lockdown &&
          !state.strictRuntime;

      Future<void> persist() async {
        await _smartRouteApps.saveSelection(selection);
        if (mounted) {
          setState(() {
            _message = ru
                ? 'Выбор приложений сохранён на устройстве.'
                : 'App choices saved on this device.';
          });
        }
      }

      if (!_smartRouteRuDirect ||
          !_connected ||
          snapshot.protected ||
          !snapshot.protectionKnown ||
          !canApplyAppRoutes(protect) ||
          !snapshot.supported ||
          snapshot.legacyAppMode ||
          profile == null ||
          !SmartRouteAppsService.managedProfile(profile)) {
        await _runBusy(persist, message: s.working);
        return;
      }

      final operation = _sessionController.beginProfileSwitch();
      await _runQueuedBusy(operation, () async {
        // Protection can change in Android settings while this command is
        // queued. Never tear down a protected tunnel just to apply app routes.
        final latestProtection = await _killSwitchService.read();
        _sessionController.ensureCurrent(operation);
        if (!canApplyAppRoutes(latestProtection)) {
          await persist();
          return;
        }
        final blockReason = _profileConnectBlockReason(profile);
        if (blockReason != null) throw _ProfileConnectionBlocked(blockReason);
        // Android app exclusions are installed when the TUN is established.
        // Reload only acknowledges a broadcast; use the fenced stop and a
        // fresh start on the same profile for additions as well as removals.
        if (!await _stopVpnCore(
          updateMessage: false,
          operation: operation,
          invalidatePendingStart: true,
        )) {
          throw StateError(s.vpnStopTimeout(_status));
        }
        _sessionController.ensureCurrent(operation);
        await persist();
        _sessionController.ensureCurrent(operation);
        await _startVpnCore(
          profile,
          operation: operation,
          rapidRestart: true,
          allowInProcessReload: false,
        );
      }, message: s.smartRouteApplying);
    } finally {
      _smartRouteSettingsBusy = false;
    }
  }

  Future<void> _setDnsLeakProtection(bool enabled) async {
    final mode = enabled
        ? DnsProtectionMode.leakGuard
        : DnsProtectionMode.stable;
    if (_dnsProtectionMode == mode || _busy) {
      return;
    }

    final profile = _selectedProfile;
    final shouldRestart = _connected && profile != null;
    await _store.saveDnsProtectionMode(mode);
    if (!mounted) {
      return;
    }

    setState(() {
      _dnsProtectionMode = mode;
      _message = enabled ? s.dnsLeakGuardEnabled : s.dnsLeakGuardDisabled;
    });

    if (!shouldRestart) {
      return;
    }

    final operation = _sessionController.beginProfileSwitch();
    await _runQueuedBusy(operation, () async {
      await _stopVpnCore(updateMessage: false, operation: operation);
      await _startVpnCore(profile, operation: operation, rapidRestart: true);
    }, message: s.dnsLeakGuardApplying);
  }

  Future<void> _refreshKillSwitchState({bool applyIfNeeded = false}) async {
    final state = await _killSwitchService.read();
    if (!mounted) return;
    if (KillSwitchHttpPolicy.requiresProxy(state)) {
      KillSwitchHttpPolicy.cancelDirectRequests();
      _cancelDirectLatency(
        clearReadings:
            !state.known ||
            state.requested ||
            state.alwaysOn ||
            state.lockdown ||
            state.strictRuntime,
      );
    }
    setState(() => _killSwitchState = state);
    if (applyIfNeeded &&
        state.systemEnforced &&
        state.runtimeKnown &&
        state.vpnActive &&
        !state.strictRuntime &&
        _connected &&
        !_busy) {
      await _applyKillSwitchRoutes();
    }
  }

  Future<void> _applyKillSwitchRoutes() async {
    final profile = _selectedProfile;
    if (_busy ||
        _killSwitchApplying ||
        !_connected ||
        profile == null ||
        !_killSwitchState.systemEnforced) {
      return;
    }
    if (!_killSwitchState.runtimeKnown || !_killSwitchState.vpnActive) {
      return;
    }
    _killSwitchApplying = true;
    try {
      // Preserve strict intent before closing the TUN: VpnService's public
      // flags may temporarily return false until the next establish().
      KillSwitchHttpPolicy.cancelDirectRequests();
      _cancelDirectLatency(clearReadings: true);
      await _killSwitchService.setRequested(true);
      final operation = _sessionController.beginProfileSwitch();
      await _runQueuedBusy(
        operation,
        () async {
          await _stopVpnCore(updateMessage: false, operation: operation);
          await _startVpnCore(
            profile,
            operation: operation,
            rapidRestart: true,
          );
        },
        message: _language == _AppLanguage.ru
            ? 'Применяем строгий kill switch...'
            : 'Applying strict kill switch...',
      );
    } on Object {
      if (mounted) {
        _showSnack(
          _language == _AppLanguage.ru
              ? 'Не удалось применить строгий режим. Защиту Android не отключали.'
              : 'Unable to apply strict mode. Android protection was not disabled.',
        );
      }
    } finally {
      _killSwitchApplying = false;
      await _refreshKillSwitchState();
    }
  }

  Future<void> _openKillSwitchSettings() async {
    final ru = _language == _AppLanguage.ru;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kill switch Android'),
        content: Text(
          ru
              ? 'Включи для Yurich Connect «Постоянная VPN» и «Блокировать соединения без VPN». На HONOR: удерживай строку Yurich Connect → «Изменить» → «Разрешить соединение только через VPN». Без VPN интернет пропадёт. Строгий режим отключает Smart Route, LAN и исключения, не удаляя настройки. Для обычного режима сначала отключи защиту Android, затем нажми «Обычные маршруты» в приложении.'
              : 'Enable Always-on VPN and Block connections without VPN for Yurich Connect. On HONOR, long-press the VPN entry, then Edit. Internet will be unavailable without VPN. Strict mode suspends Smart Route, LAN and app exceptions without deleting preferences. For normal mode, disable Android protection first, then choose Normal routes in this app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(ru ? 'Отмена' : 'Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(ru ? 'Открыть настройки' : 'Open settings'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    KillSwitchHttpPolicy.cancelDirectRequests();
    _cancelDirectLatency(clearReadings: true);
    try {
      await _killSwitchService.setRequested(true);
      await _killSwitchService.openSettings();
    } on Object {
      if (mounted) {
        _showSnack(
          ru
              ? 'Открой настройки Android → VPN → Yurich Connect.'
              : 'Open Android Settings → VPN → Yurich Connect.',
        );
      }
    }
  }

  Future<void> _useNormalKillSwitchRoutes() async {
    if (_busy) return;
    final ru = _language == _AppLanguage.ru;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(ru ? 'Обычные маршруты?' : 'Use normal routes?'),
        content: Text(
          ru
              ? 'Строгий режим отключится. Smart Route, LAN и исключения снова будут применяться после переподключения. Сначала отключи защиту в Android. Для проверки держи VPN подключённым; приложение не меняет системную блокировку.'
              : 'Strict routing will be disabled. Smart Route, LAN and exceptions resume after reconnection. Disable Android protection first and keep VPN connected for verification. This app does not change system lockdown.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(ru ? 'Отмена' : 'Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(ru ? 'Обычные маршруты' : 'Normal routes'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    try {
      await _killSwitchService.setRequested(false);
      await _refreshKillSwitchState();
    } on Object {
      if (mounted) {
        _showSnack(
          ru
              ? 'Сначала отключи защиту Android и проверь состояние при подключённом VPN.'
              : 'Disable Android protection first and verify with VPN connected.',
        );
      }
    }
  }

  Future<List<String>> _smartRouteBypassPackages() async {
    return _smartRouteRuDirect
        ? SmartRouteRules.ruBypassPackages(const [])
        : const [];
  }

  Future<void> _deleteProfile(VpnProfile profile) async {
    if (_busy || _preparingAutoConnect) {
      return;
    }

    final operation = _connected && _selectedProfileId == profile.id
        ? _sessionController.beginDisconnect()
        : _sessionController.beginMaintenance();
    await _runQueuedBusy(operation, () async {
      final wasSelected = _selectedProfileId == profile.id;
      if (wasSelected && _connected) {
        _autoRecoveryArmed = false;
        await _stopVpnCore(updateMessage: true, operation: operation);
      }

      final next = _profiles
          .where((item) => item.id != profile.id)
          .toList(growable: false);
      final nextSelectedId = wasSelected
          ? (next.isEmpty ? null : next.first.id)
          : _selectedProfileId;

      await _store.rememberDeletedSubscriptionProfile(profile);
      await _persistProfiles(next);
      await _store.saveSelectedProfileId(nextSelectedId);
      if (!mounted) {
        return;
      }
      setState(() {
        _profiles = next;
        _selectedProfileId = nextSelectedId;
        _directReadings.remove(profile.id);
        _profilePingMs.remove(profile.id);
        _lastSuccessfulPlanByProfileId.remove(profile.id);
        _profilePingBusy.remove(profile.id);
        _profileProbeResults.remove(profile.id);
        _profilePingCheckedAt.remove(profile.id);
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

  Future<void> _runQueuedBusy(
    VpnSessionOperation operation,
    Future<void> Function() action, {
    String? message,
    LocalConnectionIncidentAttempt? incident,
  }) async {
    _invalidateProfileProbes();
    try {
      await _sessionController.enqueue(
        operation,
        () => _runBusy(
          action,
          message: message,
          operation: operation,
          incident: incident,
        ),
      );
    } on VpnSessionCancelled catch (error) {
      _queueLog('VPN command cancelled: $error');
    }
    if (mounted &&
        _sessionController.isCurrent(operation) &&
        _status == AurumVpnStatus.started &&
        !_busy &&
        !_connectionQueueActive) {
      final selected = _explicitSelectedProfile;
      if (selected != null) unawaited(_pingProfile(selected));
    }
  }

  Future<void> _runBusy(
    Future<void> Function() action, {
    String? message,
    VpnSessionOperation? operation,
    LocalConnectionIncidentAttempt? incident,
  }) async {
    if (_busy) {
      return;
    }
    if (operation != null) {
      _dismissConnectionErrorSnack();
    }
    final command = operation?.command;
    final vpnCommand =
        command != null && command != VpnSessionCommand.maintenance;
    setState(() {
      _busy = true;
      if (vpnCommand) _vpnUiCommandFailed = false;
      _message = message ?? s.working;
    });
    try {
      await action();
    } on VpnSessionCancelled catch (error) {
      _queueLog('VPN command superseded: $error');
    } on Object catch (error) {
      final errorText = error is _AutoPassExhausted
          ? s.autoExhausted
          : _redactSensitive('$error');
      if (operation != null && !_sessionController.isCurrent(operation)) {
        _queueLog('Ignored error from superseded VPN command: $errorText');
        return;
      }
      if (mounted) {
        if (error is _AutoNetworkUnavailable) {
          setState(() {
            _lastError = null;
            _vpnUiCommandFailed = false;
            _message = s.autoNetworkWaitExpired;
          });
          return;
        }
        setState(() {
          _lastError = errorText;
          if (command != null && command != VpnSessionCommand.maintenance) {
            _vpnUiCommandFailed = true;
            _rememberVpnFailure(errorText, command.name);
          }
          _message = errorText;
        });
        if (operation != null &&
            command == VpnSessionCommand.connect &&
            incident != null) {
          unawaited(_queueTerminalIncident(incident, operation));
        }
        final brief = vpnCommand && !widget.tvMode;
        final errorSnack = _showSnack(
          brief && error is! _AutoPassExhausted
              ? s.vpnFailureMessage(_lastVpnFailureCategory)
              : errorText,
          duration: brief ? const Duration(seconds: 3) : null,
          action: brief
              ? null
              : SnackBarAction(
                  label: s.report,
                  onPressed: () => unawaited(_emailDeveloper()),
                ),
        );
        if (operation != null) {
          _connectionErrorSnackBar = errorSnack;
        }
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _rememberVpnFailure(String message, String operation) {
    final category = message == 'unexpected-stop'
        ? 'unexpected_stop'
        : ProtocolTestMetadata.failure([message]);
    _lastVpnFailureCategory = category;
    final profile = _explicitSelectedProfile;
    final protocol = profile == null
        ? 'unknown'
        : ProtocolDisplayMapper.mapProfile(profile);
    _recordStabilityEvent(
      'vpn-failure: operation=$operation protocol=$protocol category=$category',
    );
  }

  void _dismissConnectionErrorSnack() {
    final errorSnack = _connectionErrorSnackBar;
    _connectionErrorSnackBar = null;
    errorSnack?.close();
  }

  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _showSnack(
    String text, {
    SnackBarAction? action,
    Duration? duration,
  }) {
    if (!mounted) {
      return null;
    }
    _connectionErrorSnackBar = null;
    final messenger = ScaffoldMessenger.of(context)..clearSnackBars();
    final snack = messenger.showSnackBar(
      SnackBar(
        content: Text(text),
        action: action,
        duration: duration ?? const Duration(seconds: 4),
      ),
    );
    unawaited(
      snack.closed.then((_) {
        if (identical(_connectionErrorSnackBar, snack)) {
          _connectionErrorSnackBar = null;
        }
      }),
    );
    return snack;
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

    final distributionChannel = await _loadDistributionChannel();
    if (!mounted) {
      return;
    }
    if (_distributionChannel != distributionChannel) {
      setState(() => _distributionChannel = distributionChannel);
    }
    switch (distributionChannel) {
      case AppDistributionChannel.github:
        break;
      case AppDistributionChannel.tv:
        await _openUrl(
          'https://github.com/ivan-yurich/Yurich-Connect-Android/releases',
        );
        return;
      case AppDistributionChannel.play:
        _showSnack(s.playUpdatesOnly);
        await _openUrl(_playStoreUrl);
        return;
      case AppDistributionChannel.soak:
        _showSnack(s.soakUpdatesDisabled);
        return;
      case AppDistributionChannel.unknown:
        _showSnack(s.updateChannelUnavailable);
        return;
    }

    setState(() {
      _updateBusy = true;
      _updateProgress = null;
      _updateMessage = s.updateChecking;
    });
    _lastUpdateNoticeAttempt = _updateNoticeClock.elapsed;

    try {
      final abis = await _updateService.supportedAbis().timeout(
        const Duration(seconds: 4),
        onTimeout: () => const <String>[],
      );
      final update = await _updateService.findLatest(
        currentVersion: _appVersion,
        supportedAbis: abis,
        timeout: _manualUpdateCheckTimeout,
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
        expectedVersion: update.version,
      );
      if (mounted) {
        setState(() => _updateMessage = s.updateInstallerOpened);
      }
    } on TimeoutException {
      if (mounted) {
        setState(() => _updateMessage = s.updateCheckTimedOut);
        _showSnack(
          s.updateCheckTimedOut,
          action: SnackBarAction(
            label: s.retry,
            onPressed: () => unawaited(_checkAndInstallUpdate()),
          ),
        );
      }
    } on AppUpdateArchitectureException {
      if (mounted) {
        setState(() => _updateMessage = s.updateArchitectureUnavailable);
        _showSnack(s.updateArchitectureUnavailable);
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
                        AppUpdateService.manualDownloadUri(_appVersion))
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
    if (_updateBusy ||
        !_distributionChannel.externalUpdatesEnabled ||
        !AppUpdateNoticePolicy.shouldCheck(
          elapsed: _updateNoticeClock.elapsed,
          lastAttempt: _lastUpdateNoticeAttempt,
          inFlight: _updateNoticeCheckInFlight,
          foreground: _uiForeground,
        )) {
      return;
    }
    _updateNoticeCheckInFlight = true;
    _lastUpdateNoticeAttempt = _updateNoticeClock.elapsed;
    try {
      if (!(await _updateService.distributionChannel())
          .externalUpdatesEnabled) {
        return;
      }
      final abis = await _updateService.supportedAbis().timeout(
        const Duration(seconds: 4),
        onTimeout: () => const <String>[],
      );
      final update = await _updateService.findLatest(
        currentVersion: _appVersion,
        supportedAbis: abis,
        timeout: const Duration(seconds: 26),
      );
      if (!mounted || _updateBusy) {
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

      if (_updateNoticeShownForVersion == update.version) {
        return;
      }
      _updateNoticeShownForVersion = update.version;
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
    } finally {
      _updateNoticeCheckInFlight = false;
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
    final engineSelection = profile == null
        ? null
        : ProfileEngineSelector.select(profile);
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
      'dns_protection_mode: ${_dnsProtectionMode.storageValue}',
      'smart_route_enabled: $_smartRouteRuDirect',
      if (_smartRouteRuDirect) ...[
        'smart_route_mode: service-allowlist-direct/default-vpn',
        'smart_route_compiled_direct_domains: ${SmartRouteRules.directDomainRules.domains.length + SmartRouteRules.directDomainRules.domainSuffixes.length}',
        'smart_route_domain_control: yandex=${SmartRouteRules.domainOutbound('yandex.ru')}, google=${SmartRouteRules.domainOutbound('google.ru')}, unknown=${SmartRouteRules.domainOutbound('unknown.example.ru')}',
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
      'network_type: $_networkType',
      'network_label: $_networkTypeLabel',
      'network_generation: $_networkGenerationId',
      'network_changing: $_networkChanging',
      if (_networkFingerprint.isNotEmpty)
        'network_fingerprint: $_networkFingerprint',
      if (_lastNetworkSnapshotAt != null)
        'last_network_snapshot_local: ${_lastNetworkSnapshotAt!.toIso8601String()}',
      if (_networkChangingUntil != null)
        'network_changing_until_local: ${_networkChangingUntil!.toIso8601String()}',
      if (_lastNativeActivityAt != null)
        'last_native_activity_local: ${_lastNativeActivityAt!.toIso8601String()}',
      'manual_disconnect_requested: $_manualDisconnectRequested',
      'message: ${_redactSensitive(_message)}',
      if (_lastError != null) 'last_error: $_lastError',
      'uptime: ${_formatDuration(_connectedDuration)}',
      'auto_recovery_armed: $_autoRecoveryArmed',
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
      if (_lastTrafficAt != null)
        'last_traffic_local: ${_lastTrafficAt!.toIso8601String()}',
      if (_lastHealthyAt != null)
        'last_healthy_local: ${_lastHealthyAt!.toIso8601String()}',
      if (profile != null) ...[
        'profile: ${_redactSensitive(profile.name)}',
        'protocol: ${ProtocolDisplayMapper.mapProfile(profile)}',
        if (engineSelection != null) ...[
          'core_engine: ${engineSelection.engine.name}',
          'core_version: ${engineSelection.coreVersion}',
          'protocol_support: ${engineSelection.supportLevel.name}',
        ],
        if (_profileUsesWarpExit(profile)) ...[
          'transport_mode: warp',
          'dns_mode: warp/proxy',
          'expected_geo: Cloudflare/WARP exit, not pure VPS location',
        ],
        'endpoint: ${_redactSensitive(profile.endpoint)}',
        'country: ${_profileCountryFlag(profile) ?? 'unknown'}'
            '${_profileCountryCode(profile) == null ? '' : ' ${_profileCountryCode(profile)}'}'
            '${_profileCountryName(profile) == null ? '' : ' ${_profileCountryName(profile)}'}',
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
        'profile_network_stats: ${_profileNetworkStatsSummary(profile)}',
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
            ProtocolDisplayMapper.mapProfile(item),
            _redactSensitive(item.endpoint),
            'country=${_profileCountryFlag(item) ?? 'unknown'}'
                '${_profileCountryCode(item) == null ? '' : ' ${_profileCountryCode(item)}'}',
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
        .where((log) => !SingBoxLogFilter.isDiagnosticNoise(log))
        .map(_redactSensitive);
    lines.addAll(safeLogs.isEmpty ? const ['Логов пока нет.'] : safeLogs);
    return lines.join('\n');
  }

  bool _profileUsesWarpExit(VpnProfile profile) {
    return profile.kind == VpnProfileKind.hysteria ||
        profile.kind == VpnProfileKind.hysteria2;
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
      final yurichRuntime = (map['_yurich'] as Map?)?.cast<String, dynamic>();
      if (yurichRuntime?['core'] == XrayConfigBuilder.runtimeCore) {
        final xray = (map['xray'] as Map?)?.cast<String, dynamic>();
        if (xray == null) {
          return 'target=${target.name}; core=xray; invalid wrapper';
        }
        return _summarizeXrayConfig(xray, target: target);
      }
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
            (rule['domain_suffix'] as List?)?.contains('gosuslugi.ru') == true,
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
      final dnsDetour = dnsServer['detour'];
      final hasRemoteDns = dnsServers.whereType<Map>().any((server) {
        final tag = server['tag'];
        return tag == 'remote-dns' ||
            (tag is String &&
                (tag == 'remote-dns-primary' || tag == 'remote-dns-secondary'));
      });
      return [
        'target=${target.name}',
        'proxy=${proxy['type'] ?? 'unknown'}',
        'dns=$dnsFinal/${dnsServer['type'] ?? 'unknown'}',
        if (hasRemoteDns) 'dns_leak_guard=true',
        if (dnsDetour != null) 'dns_detour=$dnsDetour',
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

  String _summarizeXrayConfig(
    Map<String, dynamic> map, {
    required SingBoxConfigTarget target,
  }) {
    final inbounds = ((map['inbounds'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();
    final tun = inbounds.firstWhere(
      (inbound) => inbound['protocol'] == 'tun',
      orElse: () => const <String, dynamic>{},
    );
    final tunSettings =
        (tun['settings'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};

    final outbounds = ((map['outbounds'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();
    final proxy = outbounds.firstWhere(
      (outbound) => outbound['tag'] == 'proxy',
      orElse: () =>
          outbounds.isEmpty ? const <String, dynamic>{} : outbounds.first,
    );
    final stream =
        (proxy['streamSettings'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final reality = (stream['realitySettings'] as Map?)
        ?.cast<String, dynamic>();
    final tls = (stream['tlsSettings'] as Map?)?.cast<String, dynamic>();
    final xhttp =
        (stream['xhttpSettings'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final dns = (map['dns'] as Map?)?.cast<String, dynamic>() ?? const {};
    final route = (map['routing'] as Map?)?.cast<String, dynamic>() ?? const {};
    final routeRules = ((route['rules'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();
    final smartRouteEnabled = routeRules.any(
      (rule) =>
          rule['outboundTag'] == 'direct' &&
          (rule['domain'] as List?)?.contains('domain:gosuslugi.ru') == true,
    );

    return [
      'target=${target.name}',
      'core=xray',
      'proxy=${proxy['protocol'] ?? 'unknown'}',
      'transport=${stream['network'] ?? 'unknown'}',
      'security=${stream['security'] ?? 'unknown'}',
      'xhttp_mode=${xhttp['mode'] ?? 'default'}',
      'dns=${((dns['servers'] as List?) ?? const []).join(',')}',
      'route_final=${route['final'] ?? 'missing'}',
      'smart_route=$smartRouteEnabled',
      'mtu=${tunSettings['mtu'] ?? 'unknown'}',
      'gateway=${tunSettings['gateway'] ?? 'unknown'}',
      'sni=${reality?['serverName'] ?? tls?['serverName'] ?? 'unknown'}',
      if (reality != null) 'reality=true',
      'mixed_proxy=false',
    ].join('; ');
  }

  Future<void> _setLogsExpanded(bool expanded) async {
    if (!mounted || _logsExpanded == expanded) {
      return;
    }
    setState(() => _logsExpanded = expanded);

    if (!expanded) {
      final subscription = _logSubscription;
      _logSubscription = null;
      _pendingLogs.clear();
      _logFlushTimer?.cancel();
      _logFlushTimer = null;
      await subscription?.cancel();
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
    return SensitiveDataRedactor.redact(value);
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

        void applyLogs() {
          _logs.addAll(_pendingLogs);
          _pendingLogs.clear();
          if (_logs.length > _maxStoredLogs) {
            _logs.removeRange(0, _logs.length - _maxStoredLogs);
          }
        }

        if (_uiForeground) {
          setState(applyLogs);
        } else {
          applyLogs();
        }
      } on Object catch (error, stackTrace) {
        _handleEngineStreamError('log-flush', error, stackTrace);
      }
    });
  }

  String _cleanLog(String message) {
    return message.replaceAll(_logAnsiEscapePattern, '').trim();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedProfile;
    final explicitSelected = _explicitSelectedProfile;
    final connectCandidate = _connected
        ? selected
        : (explicitSelected ?? _autoConnectProfile() ?? selected);
    final selectedProfileId = _connected
        ? (_selectedProfileId ?? selected?.id)
        : (_selectedProfileId ?? selected?.id ?? connectCandidate?.id);
    final activeProfileId = _connected ? selectedProfileId : null;

    if (widget.tvMode) {
      return TvHomeScreen(
        russian: _language == _AppLanguage.ru,
        connection: _connectionUiState,
        connected: _connected,
        busy: _busy,
        message: SensitiveDataRedactor.redact(_message),
        uptime: _formatDuration(_connectedDuration),
        version: _appVersion,
        smartRoute: _smartRouteRuDirect,
        autoDns: _dnsProtectionMode.protectsAgainstLeaks,
        refreshing: _subscriptionRefreshBusy,
        logs: _logs.map(SensitiveDataRedactor.redact).toList(growable: false),
        profiles: [
          for (final profile in _profiles)
            TvProfileItem(
              id: profile.id,
              name: _profileDisplayName(profile),
              protocol: ProtocolDisplayMapper.mapProfile(profile),
              country: _profileCountryFlag(profile) ?? '',
              latency: _profilePingLabel(profile),
              group: switch (profile.kind) {
                VpnProfileKind.vlessXhttp => TvProtocolGroup.xhttp,
                VpnProfileKind.naive => TvProtocolGroup.naive,
                VpnProfileKind.hysteria ||
                VpnProfileKind.hysteria2 => TvProtocolGroup.hysteria,
                _ => TvProtocolGroup.vless,
              },
              selected: profile.id == selectedProfileId,
              active: profile.id == activeProfileId,
            ),
        ],
        onToggle: () => unawaited(_toggleVpn()),
        onSelect: (id) => unawaited(
          _selectProfile(_profiles.firstWhere((profile) => profile.id == id)),
        ),
        onImport: () => unawaited(_showImportSheet()),
        onRefresh: () => unawaited(_refreshSubscriptions()),
        onSmartRoute: (enabled) => unawaited(_setSmartRouteRuDirect(enabled)),
        onAutoDns: (enabled) => unawaited(_setDnsLeakProtection(enabled)),
        onLogsVisible: (visible) => unawaited(_setLogsExpanded(visible)),
        onLanguage: () => unawaited(
          _setLanguage(
            _language == _AppLanguage.ru ? _AppLanguage.en : _AppLanguage.ru,
          ),
        ),
        onReleases: () => unawaited(_checkAndInstallUpdate()),
        onPrivacy: () => unawaited(_openUrl(_privacyPolicyUrl)),
      );
    }

    return _buildMobile(selected, explicitSelected, connectCandidate);
  }

  void _navigateMobile(_MobilePage page) {
    if (_mobilePage == page) return;
    _dismissConnectionErrorSnack();
    if (page != _MobilePage.settings && _logsExpanded) {
      unawaited(_setLogsExpanded(false));
    }
    setState(() => _mobilePage = page);
    if (page == _MobilePage.settings) {
      unawaited(_refreshBatteryOptimizationStatus());
    }
  }

  void _changeMobileSupportTab(_SupportTab tab) {
    if (_supportTab != tab) setState(() => _supportTab = tab);
  }
}
