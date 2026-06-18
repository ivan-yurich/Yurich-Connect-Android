class ProfileStabilityStats {
  const ProfileStabilityStats({
    this.successfulStarts = 0,
    this.failedStarts = 0,
    this.recoveries = 0,
    this.healthFailures = 0,
    this.lastStartedAt,
    this.lastHealthyAt,
    this.lastFailureAt,
    this.lastFailureReason,
  });

  final int successfulStarts;
  final int failedStarts;
  final int recoveries;
  final int healthFailures;
  final DateTime? lastStartedAt;
  final DateTime? lastHealthyAt;
  final DateTime? lastFailureAt;
  final String? lastFailureReason;

  int autoSelectPenalty({DateTime? now}) {
    final current = (now ?? DateTime.now()).toUtc();
    var penalty = failedStarts * 90 + healthFailures * 45 + recoveries * 30;
    penalty -= successfulStarts.clamp(0, 8) * 12;

    final lastFailure = lastFailureAt;
    if (lastFailure != null) {
      final age = current.difference(lastFailure.toUtc());
      if (age < const Duration(minutes: 15)) {
        penalty += 320;
      } else if (age < const Duration(hours: 1)) {
        penalty += 180;
      } else if (age < const Duration(hours: 6)) {
        penalty += 80;
      }
    }

    final lastHealthy = lastHealthyAt;
    if (lastHealthy != null &&
        current.difference(lastHealthy.toUtc()) < const Duration(minutes: 20)) {
      penalty = (penalty * 0.45).round();
    }

    return penalty.clamp(0, 900);
  }

  bool isTemporarilyUnstable({DateTime? now}) {
    final lastFailure = lastFailureAt;
    if (lastFailure == null) {
      return false;
    }
    final failures = failedStarts + healthFailures + recoveries;
    if (failures < 3) {
      return false;
    }
    final age = (now ?? DateTime.now()).toUtc().difference(lastFailure.toUtc());
    return age < const Duration(minutes: 30);
  }

  ProfileStabilityStats recordStartSuccess({DateTime? at}) {
    final current = (at ?? DateTime.now()).toUtc();
    return copyWith(
      successfulStarts: successfulStarts + 1,
      lastStartedAt: current,
      lastHealthyAt: current,
      healthFailures: healthFailures > 0 ? healthFailures - 1 : 0,
    );
  }

  ProfileStabilityStats recordStartFailure(String reason, {DateTime? at}) {
    final current = (at ?? DateTime.now()).toUtc();
    return copyWith(
      failedStarts: failedStarts + 1,
      lastFailureAt: current,
      lastFailureReason: reason,
    );
  }

  ProfileStabilityStats recordHealthFailure(String reason, {DateTime? at}) {
    final current = (at ?? DateTime.now()).toUtc();
    return copyWith(
      healthFailures: healthFailures + 1,
      lastFailureAt: current,
      lastFailureReason: reason,
    );
  }

  ProfileStabilityStats recordRecovery({DateTime? at}) {
    final current = (at ?? DateTime.now()).toUtc();
    return copyWith(recoveries: recoveries + 1, lastStartedAt: current);
  }

  ProfileStabilityStats recordHealthy({DateTime? at}) {
    return copyWith(lastHealthyAt: (at ?? DateTime.now()).toUtc());
  }

  ProfileStabilityStats copyWith({
    int? successfulStarts,
    int? failedStarts,
    int? recoveries,
    int? healthFailures,
    DateTime? lastStartedAt,
    DateTime? lastHealthyAt,
    DateTime? lastFailureAt,
    String? lastFailureReason,
  }) {
    return ProfileStabilityStats(
      successfulStarts: successfulStarts ?? this.successfulStarts,
      failedStarts: failedStarts ?? this.failedStarts,
      recoveries: recoveries ?? this.recoveries,
      healthFailures: healthFailures ?? this.healthFailures,
      lastStartedAt: lastStartedAt ?? this.lastStartedAt,
      lastHealthyAt: lastHealthyAt ?? this.lastHealthyAt,
      lastFailureAt: lastFailureAt ?? this.lastFailureAt,
      lastFailureReason: lastFailureReason ?? this.lastFailureReason,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'successfulStarts': successfulStarts,
      'failedStarts': failedStarts,
      'recoveries': recoveries,
      'healthFailures': healthFailures,
      'lastStartedAt': lastStartedAt?.toIso8601String(),
      'lastHealthyAt': lastHealthyAt?.toIso8601String(),
      'lastFailureAt': lastFailureAt?.toIso8601String(),
      'lastFailureReason': lastFailureReason,
    };
  }

  factory ProfileStabilityStats.fromJson(Map<String, dynamic> json) {
    return ProfileStabilityStats(
      successfulStarts: _parseInt(json['successfulStarts']),
      failedStarts: _parseInt(json['failedStarts']),
      recoveries: _parseInt(json['recoveries']),
      healthFailures: _parseInt(json['healthFailures']),
      lastStartedAt: _parseDateTime(json['lastStartedAt']),
      lastHealthyAt: _parseDateTime(json['lastHealthyAt']),
      lastFailureAt: _parseDateTime(json['lastFailureAt']),
      lastFailureReason: json['lastFailureReason'] as String?,
    );
  }

  static int _parseInt(Object? value) {
    return switch (value) {
      int() => value,
      num() => value.toInt(),
      String() => int.tryParse(value) ?? 0,
      _ => 0,
    };
  }

  static DateTime? _parseDateTime(Object? value) {
    return switch (value) {
      DateTime() => value.toUtc(),
      int() => DateTime.fromMillisecondsSinceEpoch(value, isUtc: true),
      String() => DateTime.tryParse(value)?.toUtc(),
      _ => null,
    };
  }
}
