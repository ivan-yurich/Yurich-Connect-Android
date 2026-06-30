class ProfileNetworkStabilityStats {
  const ProfileNetworkStabilityStats({
    this.successfulStarts = 0,
    this.recoveries = 0,
    this.healthFailures = 0,
    this.trafficBytes = 0,
    this.lastHealthyAt,
    this.lastFailureAt,
    this.lastFailureReason,
  });

  final int successfulStarts;
  final int recoveries;
  final int healthFailures;
  final int trafficBytes;
  final DateTime? lastHealthyAt;
  final DateTime? lastFailureAt;
  final String? lastFailureReason;

  ProfileNetworkStabilityStats recordStartSuccess({DateTime? at}) {
    final current = (at ?? DateTime.now()).toUtc();
    return copyWith(
      successfulStarts: successfulStarts + 1,
      lastHealthyAt: current,
      healthFailures: healthFailures > 0 ? healthFailures - 1 : 0,
    );
  }

  ProfileNetworkStabilityStats recordHealthFailure(
    String reason, {
    DateTime? at,
  }) {
    final current = (at ?? DateTime.now()).toUtc();
    return copyWith(
      healthFailures: healthFailures + 1,
      lastFailureAt: current,
      lastFailureReason: reason,
    );
  }

  ProfileNetworkStabilityStats recordRecovery({DateTime? at}) {
    return copyWith(
      recoveries: recoveries + 1,
      lastHealthyAt: (at ?? DateTime.now()).toUtc(),
    );
  }

  ProfileNetworkStabilityStats recordHealthy({DateTime? at}) {
    return copyWith(lastHealthyAt: (at ?? DateTime.now()).toUtc());
  }

  ProfileNetworkStabilityStats recordTraffic(int bytesDelta, {DateTime? at}) {
    if (bytesDelta <= 0) {
      return this;
    }
    return copyWith(
      trafficBytes: trafficBytes + bytesDelta,
      lastHealthyAt: (at ?? DateTime.now()).toUtc(),
    );
  }

  ProfileNetworkStabilityStats copyWith({
    int? successfulStarts,
    int? recoveries,
    int? healthFailures,
    int? trafficBytes,
    DateTime? lastHealthyAt,
    DateTime? lastFailureAt,
    String? lastFailureReason,
  }) {
    return ProfileNetworkStabilityStats(
      successfulStarts: successfulStarts ?? this.successfulStarts,
      recoveries: recoveries ?? this.recoveries,
      healthFailures: healthFailures ?? this.healthFailures,
      trafficBytes: trafficBytes ?? this.trafficBytes,
      lastHealthyAt: lastHealthyAt ?? this.lastHealthyAt,
      lastFailureAt: lastFailureAt ?? this.lastFailureAt,
      lastFailureReason: lastFailureReason ?? this.lastFailureReason,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'successfulStarts': successfulStarts,
      'recoveries': recoveries,
      'healthFailures': healthFailures,
      'trafficBytes': trafficBytes,
      'lastHealthyAt': lastHealthyAt?.toIso8601String(),
      'lastFailureAt': lastFailureAt?.toIso8601String(),
      'lastFailureReason': lastFailureReason,
    };
  }

  factory ProfileNetworkStabilityStats.fromJson(Map<String, dynamic> json) {
    return ProfileNetworkStabilityStats(
      successfulStarts: _parseInt(json['successfulStarts']),
      recoveries: _parseInt(json['recoveries']),
      healthFailures: _parseInt(json['healthFailures']),
      trafficBytes: _parseInt(json['trafficBytes']),
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
