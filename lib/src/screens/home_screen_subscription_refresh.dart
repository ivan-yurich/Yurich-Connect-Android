part of 'home_screen.dart';

const _automaticSubscriptionRefreshInterval = Duration(hours: 6);
const _busySubscriptionRefreshRetry = Duration(minutes: 1);

extension _ScheduledSubscriptionRefresh on _HomeScreenState {
  bool get _automaticSubscriptionRefreshEnabled =>
      !widget.tvMode &&
      _nativeOwnsTunnelHealth &&
      _distributionChannel != AppDistributionChannel.soak;

  DateTime _subscriptionRefreshTime() =>
      (widget.subscriptionRefreshNow ?? DateTime.now)().toUtc();

  Future<void> _loadAutomaticSubscriptionSchedule() async {
    if (!_automaticSubscriptionRefreshEnabled ||
        _subscriptionSourcesFor(_profiles).isEmpty) {
      return;
    }
    DateTime? savedDue;
    try {
      savedDue = await _store.loadNextSubscriptionRefreshAt();
    } on Object {
      if (mounted) _queueLog('Could not read subscription refresh schedule.');
    }
    if (!mounted) return;
    if (_nextSubscriptionRefreshAt == null) {
      final latestDue = _subscriptionRefreshTime().add(
        _automaticSubscriptionRefreshInterval,
      );
      if (savedDue == null || savedDue.isAfter(latestDue)) {
        await _markSubscriptionRefreshAttempt();
        return;
      }
      _nextSubscriptionRefreshAt = savedDue;
    }
    _scheduleAutomaticSubscriptionRefresh();
  }

  Future<void> _markSubscriptionRefreshAttempt() async {
    final next = _subscriptionRefreshTime().add(
      _automaticSubscriptionRefreshInterval,
    );
    _nextSubscriptionRefreshAt = next;
    _scheduleAutomaticSubscriptionRefresh();
    try {
      await _store.saveNextSubscriptionRefreshAt(next);
    } on Object {
      if (mounted) _queueLog('Could not save subscription refresh schedule.');
    }
  }

  void _scheduleAutomaticSubscriptionRefresh({Duration? retryAfter}) {
    _subscriptionRefreshTimer?.cancel();
    _subscriptionRefreshTimer = null;
    final due = _nextSubscriptionRefreshAt;
    if (!mounted ||
        !_automaticSubscriptionRefreshEnabled ||
        _automaticSubscriptionRefreshInFlight ||
        due == null ||
        _subscriptionSourcesFor(_profiles).isEmpty) {
      return;
    }
    // A suspended process catches up on resume, without replaying every missed
    // interval. A backwards clock change cannot defer the next run indefinitely.
    final delay = retryAfter ?? due.difference(_subscriptionRefreshTime());
    final boundedDelay = delay > _automaticSubscriptionRefreshInterval
        ? _automaticSubscriptionRefreshInterval
        : delay;
    _subscriptionRefreshTimer = Timer(
      boundedDelay.isNegative ? Duration.zero : boundedDelay,
      () {
        _subscriptionRefreshTimer = null;
        unawaited(_runAutomaticSubscriptionRefresh());
      },
    );
  }

  bool get _canApplyAutomaticSubscriptionRefresh =>
      mounted &&
      _soakVpnInitialized &&
      _runtimeReconciled &&
      !_busy &&
      !_subscriptionRefreshBusy &&
      !_connectionQueueActive &&
      !_preparingAutoConnect &&
      !_stoppingByUser &&
      !_stopProtectionCheck &&
      !_killSwitchApplying &&
      !_smartRouteSettingsBusy &&
      (_status == AurumVpnStatus.started &&
              _unconfirmedSwitchProfileId == null &&
              _explicitSelectedProfile != null ||
          _status == AurumVpnStatus.stopped &&
              !_sessionController.desiredRunning &&
              !_autoRecoveryArmed);

  Future<void> _runAutomaticSubscriptionRefresh() async {
    if (_automaticSubscriptionRefreshInFlight) return;
    if (!_canApplyAutomaticSubscriptionRefresh) {
      _scheduleAutomaticSubscriptionRefresh(
        retryAfter: _busySubscriptionRefreshRetry,
      );
      return;
    }

    final profilesAtStart = _profiles;
    final selectedAtStart = _selectedProfileId;
    final statusAtStart = _status;
    final generation = _sessionController.generation;
    final sources = _subscriptionSourcesFor(profilesAtStart);
    if (sources.isEmpty) return;
    final active = statusAtStart == AurumVpnStatus.started
        ? _explicitSelectedProfile
        : null;
    bool unchanged() =>
        _canApplyAutomaticSubscriptionRefresh &&
        identical(profilesAtStart, _profiles) &&
        selectedAtStart == _selectedProfileId &&
        generation == _sessionController.generation &&
        statusAtStart == _status;

    Future<bool> runtimeStillMatches() async {
      final live = await _vpnEngine.getVPNStatus().timeout(_nativeShortTimeout);
      return unchanged() && live == statusAtStart;
    }

    _automaticSubscriptionRefreshInFlight = true;
    Duration? retryAfter = _busySubscriptionRefreshRetry;
    try {
      if (!await runtimeStillMatches()) return;
      // Record attempts, including failures, so an offline server does not
      // cause another batch of requests on every resume.
      retryAfter = null;
      await _markSubscriptionRefreshAttempt();
      final imported = <VpnProfile>[];
      final refreshedSources = <String>{};
      for (final source in sources) {
        if (!unchanged()) return;
        try {
          final fresh = _clientSupportedProfiles(
            await _importer.importFromText(
              source,
              currentTunnelOnly: active != null,
            ),
          );
          if (fresh.isEmpty) continue;
          imported.addAll(fresh);
          refreshedSources.add(source);
        } on Object {
          // User URLs and HTTP errors can contain subscription credentials.
          // Keep the automatic path silent and only log aggregate failures.
        }
      }
      if (!unchanged()) return;
      final failed = sources.length - refreshedSources.length;
      if (failed > 0) {
        _queueLog(
          'Automatic subscription refresh: $failed source(s) unavailable.',
        );
      }
      if (refreshedSources.isEmpty) return;

      final deleted = await _store.loadDeletedProfileIdsBySubscriptionSource();
      if (!unchanged() || !await runtimeStillMatches()) return;
      final fresh = _withoutDeletedSubscriptionProfiles(
        _profilesWithCachedData(imported),
        deleted,
      );
      final result = _subscriptionProfileReconciler.replaceRefreshedSources(
        existing: profilesAtStart,
        imported: [
          ...fresh,
          // Store exactly the profile owning the live config, even when the
          // subscription removed it or rotated its credentials under the same ID.
          ?active,
        ],
        refreshedSources: refreshedSources,
        selectedProfileId: selectedAtStart,
      );
      await _saveAutomaticSubscriptionProfiles(result);
    } on Object {
      if (mounted) {
        _queueLog('Automatic subscription refresh could not finish.');
      }
    } finally {
      _automaticSubscriptionRefreshInFlight = false;
      _scheduleAutomaticSubscriptionRefresh(retryAfter: retryAfter);
    }
  }
}
