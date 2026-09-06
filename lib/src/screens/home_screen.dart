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
import '../models/dns_protection_mode.dart';
import '../models/profile_network_stability.dart';
import '../models/profile_stability.dart';
import '../models/vpn_profile.dart';
import '../services/app_update_service.dart';
import '../services/first_successful_future.dart';
import '../services/fixed_size_batches.dart';
import '../services/installed_apps_service.dart';
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
import '../services/protocol_display_mapper.dart';
import '../services/sing_box_log_filter.dart';
import '../services/smart_route_rules.dart';
import '../services/sing_box_config_builder.dart';
import '../services/vpn_engine.dart';
import '../services/vpn_reconnect_policy.dart';
import '../services/vpn_session_controller.dart';
import '../services/subscription_profile_reconciler.dart';
import '../services/xray_config_builder.dart';
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
const _appVersionFallback = '1.0.108';
const _nativeShortTimeout = Duration(seconds: 3);
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
    VpnProfileKind.vlessReality ||
    VpnProfileKind.vlessXhttp ||
    VpnProfileKind.vlessTls => _ProfileTab.vless,
    VpnProfileKind.naive => _ProfileTab.naive,
    VpnProfileKind.hysteria2 || VpnProfileKind.hysteria => _ProfileTab.hysteria,
    VpnProfileKind.vlessMkcp || VpnProfileKind.singBoxConfig => _ProfileTab.all,
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
  final _subscriptionProfileReconciler = const SubscriptionProfileReconciler();
  final _xrayConfigBuilder = XrayConfigBuilder();
  final _autoSelector = const ProfileAutoSelector();
  final _updateService = AppUpdateService();
  final _powerManagerService = PowerManagerService();
  final _geoService = ProfileGeoService();
  final _installedAppsService = InstalledAppsService();
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
  final _profilePingText = <String, String>{};
  final _profilePingBusy = <String, bool>{};
  final _profilePingError = <String, String>{};
  final _profilePingCheckedAt = <String, DateTime>{};
  final _lastSuccessfulPlanByProfileId = <String, String>{};
  Map<String, ProfileStabilityStats> _profileStabilityStats = const {};
  Map<String, Map<String, ProfileNetworkStabilityStats>>
  _profileNetworkStabilityStats = const {};
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
  AppDistributionChannel _distributionChannel = AppDistributionChannel.unknown;
  String? _lastError;
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
  bool _runtimeReconcileInFlight = false;
  bool _runtimeReconciled = false;
  bool _soakProfilesLoaded = false;
  bool _soakVpnInitialized = false;
  bool _soakReadyAnnounced = false;
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
    if (_status == AurumVpnStatus.starting && _autoRecoveryArmed) {
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

  bool get _networkChanging => _isNetworkChanging(DateTime.now());
  bool get _connectionQueueActive => _sessionController.hasPendingOperations;

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

    void apply() {
      _networkType = nextType;
      if (nextGeneration > 0) {
        _networkGenerationId = nextGeneration;
      }
      if (nextFingerprint.isNotEmpty) {
        _networkFingerprint = nextFingerprint;
      }
      _lastNetworkSnapshotAt = now;
      if (changed) {
        _networkChangingUntil = now.add(_networkChangingSettleWindow);
        _lastNetworkEvent = '$source:$nextType#g$_networkGenerationId';
        _lastNetworkStatsTrafficBytes = _lastSessionTrafficBytes;
        _lastNetworkStatsTrafficSavedAt = null;
        _tunnelHealthFailures = 0;
        _nextTunnelHealthCheckAt = _networkChangingUntil;
      }
    }

    if (mounted && changed) {
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
      latencyLabel: profile == null ? null : _profilePingText[profile.id],
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
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
    _glowPulse = CurvedAnimation(
      parent: _glowController,
      curve: Curves.easeInOut,
    );
    _startBootTask('load', _load, timeout: const Duration(seconds: 12));
    _startBootTask('init-vpn', _initVpn, timeout: const Duration(seconds: 8));
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

  void _startBootTask(
    String label,
    Future<void> Function() task, {
    required Duration timeout,
  }) {
    unawaited(() async {
      try {
        await task().timeout(timeout);
      } on Object catch (error, stackTrace) {
        final errorText = _redactSensitive('$error');
        _recordStabilityEvent('boot-task-error:$label:$errorText');
        _queueLog('Boot task failed [$label]: $errorText');
        _queueLog(_redactSensitive(stackTrace.toString().split('\n').first));
      }
    }());
  }

  @override
  void dispose() {
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
    _glowController.dispose();
    unawaited(_vpnEngine.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _lastNetworkEvent = 'app-resume';
      unawaited(_refreshBatteryOptimizationStatus());
      unawaited(_refreshNetworkSnapshot('app-resume'));
      unawaited(_handleResumeRecovery());
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
      _setKeeperAction('resume-settle');
      await Future<void>.delayed(_resumeNetworkSettleDelay);
      if (!mounted ||
          _stoppingByUser ||
          _manualDisconnectRequested ||
          !_autoRecoveryArmed) {
        return;
      }

      final settledStatus = await _refreshVpnStatus();
      if (!mounted ||
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
    final distributionChannel = await _loadDistributionChannel();
    final storedProfiles = await _store.loadProfiles();
    final profiles = _clientSupportedProfiles(storedProfiles);
    final loadedStabilityStats = await _store.loadProfileStabilityStats();
    final loadedNetworkStabilityStats = await _store
        .loadProfileNetworkStabilityStats();
    final selectedId = await _store.loadSelectedProfileId();
    final language = _AppLanguage.fromCode(await _store.loadLanguageCode());
    final smartRouteRuDirect = await _store.loadSmartRouteRuDirect();
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
      _smartRouteRuDirect = smartRouteRuDirect;
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

  Future<void> _persistProfiles(List<VpnProfile> profiles) async {
    final snapshot = List<VpnProfile>.unmodifiable(profiles);
    await _store.saveProfiles(snapshot);
    _storedProfiles = snapshot;
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
                (status == AurumVpnStatus.starting ||
                    status == AurumVpnStatus.started);
            if (nativeManualStop || nativeManualStart) {
              unawaited(_store.saveManualDisconnectRequested(nativeManualStop));
            }
            var recoverUnexpectedStop = false;
            setState(() {
              _status = status;
              if (nativeManualStop) {
                _manualDisconnectRequested = true;
                _autoRecoveryArmed = false;
                _lastError = null;
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
                _lastRecoverySource = null;
              }
              if (status == AurumVpnStatus.started) {
                _lastError = null;
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
              if (displayChanged || healthChanged) {
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
      await _bestEffortNative(
        'updateConnectionNotification',
        _vpnEngine.updateConnectionNotification(_connectionUiState.toJson()),
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
    final vpnTransitionInFlight = _connectionQueueActive;
    if (_busy && !vpnTransitionInFlight) {
      return;
    }

    final current = _explicitSelectedProfile;
    if (current?.id == profile.id && !vpnTransitionInFlight) {
      return;
    }

    final shouldKeepRunning =
        _connected ||
        (vpnTransitionInFlight && _sessionController.desiredRunning);

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

    final operation = _sessionController.beginProfileSwitch();
    final crossEngineRestart =
        current != null &&
        ProfileEngineSelector.select(current).engine !=
            ProfileEngineSelector.select(profile).engine;
    if (mounted) {
      setState(() {
        _selectedProfileId = profile.id;
        _message = s.switchingProfile;
      });
    }
    await _runQueuedBusy(operation, () async {
      await _startVpnCore(
        profile,
        operation: operation,
        rapidRestart: true,
        crossEngineRestart: crossEngineRestart,
      );
    }, message: s.switchingProfile);
  }

  Future<void> _connect() async {
    if (!await _ensureVpnDisclosureConsent() || !mounted) {
      return;
    }
    final profile = _explicitSelectedProfile ?? _autoConnectProfile();
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

    final operation = _sessionController.beginConnect();
    await _store.saveManualDisconnectRequested(false);
    if (!mounted) {
      return;
    }
    setState(() {
      _manualDisconnectRequested = false;
    });
    unawaited(_refreshBatteryOptimizationStatus(prompt: true));
    _autoRecoveryArmed = true;
    await _runQueuedBusy(operation, () async {
      try {
        if (_selectedProfileId != profile.id) {
          setState(() {
            _selectedProfileId = profile.id;
            _profileTab = _profileTabForKind(profile.kind);
            _message = s.autoSelectedProfile(profile.name);
          });
          await _store.saveSelectedProfileId(profile.id);
        }
        await _startVpnCore(profile, operation: operation, rapidRestart: false);
      } on VpnSessionCancelled {
        rethrow;
      } on Object catch (error) {
        _autoRecoveryArmed = false;
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
        rethrow;
      }
    }, message: s.connectingTo(profile.name));
  }

  Future<bool> _ensureVpnDisclosureConsent() async {
    if (await _store.loadVpnDisclosureVersion() >= _vpnDisclosureVersion) {
      return true;
    }
    if (!mounted) {
      return false;
    }

    final isRussian = _language == _AppLanguage.ru;
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
                      'Для маршрутизации и диагностики приложение локально обрабатывает DNS-запросы, адреса назначений, объём трафика и состояние соединения. Эти диагностические данные автоматически не отправляются разработчику и не используются для рекламы. Оператор выбранного VPN-сервера может обрабатывать сетевой трафик согласно своей политике.\n\n'
                      'Подключение не начнётся без вашего явного согласия.'
                : 'Yurich Connect uses Android VpnService to route device traffic through the VPN server you select and encrypt the connection to the tunnel endpoint.\n\n'
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
      offlineProfileIds: _profilePingError.keys.toSet(),
      stabilityStats: _profileStabilityStats,
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
    if (mounted) {
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
    if (mounted) {
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
    bool crossEngineRestart = false,
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
    );

    _ignoreStoppedUntil = DateTime.now().add(const Duration(seconds: 18));
    final status = await _refreshVpnStatus(
      operation: operation,
      allowCachedOnError: false,
    );
    var useInProcessReload =
        rapidRestart && !crossEngineRestart && status == AurumVpnStatus.started;
    if (status != AurumVpnStatus.stopped && !useInProcessReload) {
      final stopped = await _stopVpnCore(
        updateMessage: false,
        operation: operation,
        stopCallTimeout: reconnectPolicy.stopCallTimeout,
        stopStatusTimeout: reconnectPolicy.stopStatusTimeout,
      );
      if (!stopped) {
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

    for (
      var planIndex = 0;
      planIndex < plans.length && !connected;
      planIndex += 1
    ) {
      _sessionController.ensureCurrent(operation);
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
      final saved = await _nativeCall(
        'saveConfig',
        _vpnEngine.saveConfig(config),
        timeout: _reconnectPhaseTimeout(
          reconnectPolicy,
          attemptClock,
          reconnectPolicy.configTimeout,
        ),
      );
      if (!saved) {
        throw StateError(s.configSaveFailed);
      }

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
            _message = plans.length > 1
                ? '${s.connectingStatus(profile.name)} · ${plan.label}'
                : s.connectingStatus(profile.name);
            _uplink = '0 B/s';
            _downlink = '0 B/s';
            _sessionTotal = '0 B';
            _lastConfigSummary = configSummary;
          });
        }

        final reloadInProcess = useInProcessReload;
        useInProcessReload = false;
        bool started;
        try {
          started = await _nativeCall(
            reloadInProcess ? 'reloadVPN' : 'startVPN',
            reloadInProcess ? _vpnEngine.reloadVPN() : _vpnEngine.startVPN(),
            timeout: _reconnectPhaseTimeout(
              reconnectPolicy,
              attemptClock,
              reconnectPolicy.startCallTimeout,
            ),
          );
          _sessionController.ensureCurrent(operation);
        } on VpnSessionCancelled {
          rethrow;
        } on Object catch (error) {
          started = false;
          lastStartError = _redactSensitive('$error');
        }
        if (started) {
          final finalStatus = await _waitForVpnStatus(
            {AurumVpnStatus.started},
            timeout: reconnectPolicy.statusTimeout,
            operation: operation,
          );
          if (finalStatus == AurumVpnStatus.started) {
            _sessionController.ensureCurrent(operation);
            final requiresSuccessfulProbe =
                ProfileEngineSelector.requiresSuccessfulStartupProbe(profile);
            if (!requiresSuccessfulProbe) {
              connected = true;
              successfulPlanLabel = plan.label;
              break;
            }

            final probeTimeout = reconnectPolicy.startupProbeTimeout;
            final probePassed = await _sessionController.cancelWhenSuperseded(
              operation,
              _probeLocalMixedProxy(attempts: 1).timeout(
                probeTimeout,
                onTimeout: () {
                  _queueLog('Startup proxy probe timed out.');
                  return false;
                },
              ),
            );
            _sessionController.ensureCurrent(operation);
            if (probePassed) {
              connected = true;
              successfulPlanLabel = plan.label;
              break;
            } else {
              lastStartError = s.vpnStartFailed;
              _queueLog(
                'Startup proxy probe failed for ${profile.kind.name}; '
                'restarting the tunnel before reporting Connected.',
              );
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
          final stopped = await _stopVpnCore(
            updateMessage: false,
            operation: operation,
            stopCallTimeout: reconnectPolicy.stopCallTimeout,
            stopStatusTimeout: reconnectPolicy.stopStatusTimeout,
          );
          if (!stopped) {
            throw TimeoutException(
              s.vpnStopTimeout(_status),
              reconnectPolicy.stopStatusTimeout,
            );
          }
          if (attempt < reconnectPolicy.maxAttemptsPerPlan) {
            await _delayForOperation(reconnectPolicy.retryDelay, operation);
            await _bestEffortNative(
              'saveConfig retry',
              _vpnEngine.saveConfig(config),
              timeout: _nativeConfigTimeout,
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
      throw StateError('${lastStartError ?? s.vpnStartFailed}');
    }
    if (successfulPlanLabel != null) {
      _lastSuccessfulPlanByProfileId[profile.id] = successfulPlanLabel;
    }

    _sessionController.ensureCurrent(operation);
    await _delayForOperation(
      rapidRestart
          ? const Duration(milliseconds: 100)
          : const Duration(milliseconds: 250),
      operation,
    );
    _sessionController.ensureCurrent(operation);
    await _store.saveSelectedProfileId(profile.id);
    if (mounted) {
      final connectedAt = DateTime.now();
      setState(() {
        _selectedProfileId = profile.id;
        _lastError = null;
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
    unawaited(_refreshConnectedCountry(profile.id));
  }

  String? _profileConnectBlockReason(VpnProfile profile) {
    final selection = ProfileEngineSelector.select(profile);
    if (!selection.canRunInCurrentBuild) {
      return selection.reason;
    }
    if (!profile.kind.isClientSupported) {
      return s.unsupportedProtocol(profile.kind);
    }

    return null;
  }

  Future<void> _disconnect() async {
    final operation = _sessionController.beginDisconnect();
    _autoRecoveryArmed = false;
    await _store.saveManualDisconnectRequested(true);
    if (!mounted) {
      return;
    }
    setState(() {
      _manualDisconnectRequested = true;
    });
    await _runQueuedBusy(operation, () async {
      await _stopVpnCore(operation: operation);
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
    Duration stopStatusTimeout = const Duration(seconds: 20),
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
      final status = await _refreshVpnStatus(
        operation: operation,
        allowCachedOnError: false,
      );
      if (operation != null) {
        _sessionController.ensureCurrent(operation);
      }
      var nativeStopped = status == AurumVpnStatus.stopped;
      if (status != AurumVpnStatus.stopped) {
        await _vpnEngine.stopVPN().timeout(
          stopCallTimeout,
          onTimeout: () {
            _queueLog('Native call timeout [stopVPN]');
            return true;
          },
        );
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
              _message = error;
            });
          }
          return false;
        }
        // Stopped is emitted only after the native runtime has released the
        // active tunnel. A short guard is enough before saving the next config.
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }

      if (nativeStopped && mounted) {
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
      if (mounted && _status != status) {
        setState(() => _status = status);
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
  }) async {
    if (operation != null) {
      _sessionController.ensureCurrent(operation);
    }
    final deadline = DateTime.now().add(timeout);
    var latest = _status;
    while (DateTime.now().isBefore(deadline)) {
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
      final healthy = await firstSuccessfulFuture(
        endpoints.map(
          (endpoint) =>
              _probeLocalMixedProxyEndpoint(endpoint, logFailures: logFailures),
        ),
      );
      if (healthy) {
        return true;
      }

      if (attempt < attempts) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }

    return false;
  }

  Future<bool> _probeLocalMixedProxyEndpoint(
    ({Uri uri, bool allowCertificateMismatch}) endpoint, {
    required bool logFailures,
  }) async {
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
    return false;
  }

  Future<void> _pingProfiles(
    List<VpnProfile> profiles, {
    bool force = false,
  }) async {
    if (_pingAllInFlight || profiles.isEmpty) {
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

    _pingAllInFlight = true;
    try {
      for (final batch in fixedSizeBatches(orderedProfiles, size: 4)) {
        if (!mounted) {
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

  Future<void> _pingProfile(VpnProfile profile, {bool force = false}) async {
    final server = profile.server?.trim();
    final port = profile.port ?? 443;
    if (server == null || server.isEmpty || port <= 0) {
      return;
    }
    if (_profilePingBusy[profile.id] == true) {
      return;
    }
    if (_connected && !force) {
      if (mounted) {
        setState(() {
          _profilePingBusy.remove(profile.id);
          _profilePingError.remove(profile.id);
        });
      }
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

      Object? connectError;
      for (var attempt = 0; attempt < 2; attempt++) {
        stopwatch
          ..reset()
          ..start();
        try {
          socket = await Socket.connect(
            server,
            port,
            timeout: const Duration(seconds: 4),
          );
          connectError = null;
          break;
        } on Object catch (error) {
          connectError = error;
          socket?.destroy();
          socket = null;
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
        }
      }
      if (socket == null) {
        throw connectError ?? const SocketException('TCP probe failed');
      }
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
      final index = _profiles.indexWhere((profile) => profile.id == profileId);
      final profile = index < 0 ? null : _profiles[index];
      if (profile != null &&
          ProfileCountryResolver.hasDeclaredCountry(profile)) {
        _queueLog(
          'Geo: exit country ${geo.countryCode}'
          '${geo.ip == null ? '' : ' via ${geo.ip}'}; '
          'profile country preserved',
        );
        return;
      }

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
    await _persistProfiles(next);
    if (!mounted) {
      return;
    }
    setState(() {
      _profiles = next;
    });
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

    final operation = _sessionController.beginProfileSwitch();
    await _runQueuedBusy(operation, () async {
      await _stopVpnCore(updateMessage: false, operation: operation);
      await _startVpnCore(profile, operation: operation, rapidRestart: true);
    }, message: s.smartRouteApplying);
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

  Future<List<String>> _smartRouteBypassPackages() async {
    if (!_smartRouteRuDirect) {
      return const [];
    }
    try {
      return await _installedAppsService.installedPackageNames().timeout(
        const Duration(seconds: 2),
      );
    } on Object catch (error) {
      _queueLog(
        'Smart Route installed apps scan skipped: ${_redactSensitive('$error')}',
      );
      return const [];
    }
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
        _profilePingMs.remove(profile.id);
        _lastSuccessfulPlanByProfileId.remove(profile.id);
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

  Future<void> _runQueuedBusy(
    VpnSessionOperation operation,
    Future<void> Function() action, {
    String? message,
  }) async {
    try {
      await _sessionController.enqueue(
        operation,
        () => _runBusy(action, message: message, operation: operation),
      );
    } on VpnSessionCancelled catch (error) {
      _queueLog('VPN command cancelled: $error');
    }
  }

  Future<void> _runBusy(
    Future<void> Function() action, {
    String? message,
    VpnSessionOperation? operation,
  }) async {
    if (_busy) {
      return;
    }
    if (operation != null) {
      _dismissConnectionErrorSnack();
    }
    setState(() {
      _busy = true;
      _message = message ?? s.working;
    });
    try {
      await action();
    } on VpnSessionCancelled catch (error) {
      _queueLog('VPN command superseded: $error');
    } on Object catch (error) {
      final errorText = _redactSensitive('$error');
      if (operation != null && !_sessionController.isCurrent(operation)) {
        _queueLog('Ignored error from superseded VPN command: $errorText');
        return;
      }
      if (mounted) {
        setState(() {
          _lastError = errorText;
          _message = errorText;
        });
        final errorSnack = _showSnack(
          errorText,
          action: SnackBarAction(
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

  void _dismissConnectionErrorSnack() {
    final errorSnack = _connectionErrorSnackBar;
    _connectionErrorSnackBar = null;
    errorSnack?.close();
  }

  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _showSnack(
    String text, {
    SnackBarAction? action,
  }) {
    if (!mounted) {
      return null;
    }
    _connectionErrorSnackBar = null;
    final messenger = ScaffoldMessenger.of(context)..clearSnackBars();
    final snack = messenger.showSnackBar(
      SnackBar(content: Text(text), action: action),
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

    try {
      final abis = await _updateService.supportedAbis().timeout(
        const Duration(seconds: 4),
        onTimeout: () => const <String>[],
      );
      final update = await _updateService
          .findLatest(currentVersion: _appVersion, supportedAbis: abis)
          .timeout(_manualUpdateCheckTimeout);
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
      if (!(await _updateService.distributionChannel())
          .externalUpdatesEnabled) {
        return;
      }
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
        'protocol: ${_profileKindLabel(profile.kind)}',
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
            _profileKindLabel(item.kind),
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
          (rule['domain'] as List?)?.contains('domain:ru') == true,
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
    final explicitSelected = _explicitSelectedProfile;
    final connectCandidate = _connected
        ? selected
        : (_autoConnectProfile() ?? selected);
    final panelProfile = explicitSelected ?? selected;
    final selectedProfileId = _connected
        ? (_selectedProfileId ?? selected?.id)
        : (_selectedProfileId ?? selected?.id ?? connectCandidate?.id);
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
                      selectedProfile: panelProfile,
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
                      dnsLeakProtectionEnabled:
                          _dnsProtectionMode.protectsAgainstLeaks,
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
                      onDnsLeakProtectionChanged: (enabled) =>
                          unawaited(_setDnsLeakProtection(enabled)),
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
                      distributionChannel: _distributionChannel,
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
