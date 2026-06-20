enum VpnProfileKind {
  vlessReality,
  vlessTls,
  vlessXhttp,
  vlessMkcp,
  naive,
  hysteria2,
  hysteria,
  singBoxConfig,
}

extension VpnProfileKindLabel on VpnProfileKind {
  String get label => switch (this) {
    VpnProfileKind.vlessReality => 'VLESS Reality',
    VpnProfileKind.vlessTls => 'VLESS TLS',
    VpnProfileKind.vlessXhttp => 'VLESS XHTTP',
    VpnProfileKind.vlessMkcp => 'VLESS mKCP',
    VpnProfileKind.naive => 'NaiveProxy',
    VpnProfileKind.hysteria2 => 'Hysteria2',
    VpnProfileKind.hysteria => 'Hysteria',
    VpnProfileKind.singBoxConfig => 'Sing-box',
  };

  bool get isClientSupported => switch (this) {
    VpnProfileKind.vlessReality ||
    VpnProfileKind.naive ||
    VpnProfileKind.hysteria2 ||
    VpnProfileKind.hysteria => true,
    VpnProfileKind.vlessTls ||
    VpnProfileKind.vlessXhttp ||
    VpnProfileKind.vlessMkcp ||
    VpnProfileKind.singBoxConfig => false,
  };
}

class VpnProfile {
  const VpnProfile({
    required this.id,
    required this.name,
    required this.kind,
    required this.originalInput,
    this.server,
    this.port,
    this.outbound,
    this.rawConfig,
    this.subscriptionExpiresAt,
    this.subscriptionSource,
    this.countryCode,
    this.countryName,
  });

  final String id;
  final String name;
  final VpnProfileKind kind;
  final String originalInput;
  final String? server;
  final int? port;
  final Map<String, dynamic>? outbound;
  final String? rawConfig;
  final DateTime? subscriptionExpiresAt;
  final String? subscriptionSource;
  final String? countryCode;
  final String? countryName;

  String get endpoint {
    if (server == null || server!.isEmpty) {
      return kind.label;
    }
    return port == null ? server! : '$server:$port';
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'kind': kind.name,
      'originalInput': originalInput,
      'server': server,
      'port': port,
      'outbound': outbound,
      'rawConfig': rawConfig,
      'subscriptionExpiresAt': subscriptionExpiresAt?.toIso8601String(),
      'subscriptionSource': subscriptionSource,
      'countryCode': countryCode,
      'countryName': countryName,
    };
  }

  factory VpnProfile.fromJson(Map<String, dynamic> json) {
    final kindName =
        json['kind'] as String? ?? VpnProfileKind.vlessReality.name;
    return VpnProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      kind: VpnProfileKind.values.firstWhere(
        (value) => value.name == kindName,
        orElse: () => VpnProfileKind.vlessReality,
      ),
      originalInput: json['originalInput'] as String? ?? '',
      server: json['server'] as String?,
      port: json['port'] as int?,
      outbound: (json['outbound'] as Map?)?.cast<String, dynamic>(),
      rawConfig: json['rawConfig'] as String?,
      subscriptionExpiresAt: _parseDateTime(json['subscriptionExpiresAt']),
      subscriptionSource: json['subscriptionSource'] as String?,
      countryCode: json['countryCode'] as String?,
      countryName: json['countryName'] as String?,
    );
  }

  VpnProfile copyWith({
    String? id,
    String? name,
    VpnProfileKind? kind,
    String? originalInput,
    String? server,
    int? port,
    Map<String, dynamic>? outbound,
    String? rawConfig,
    DateTime? subscriptionExpiresAt,
    String? subscriptionSource,
    String? countryCode,
    String? countryName,
  }) {
    return VpnProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      originalInput: originalInput ?? this.originalInput,
      server: server ?? this.server,
      port: port ?? this.port,
      outbound: outbound ?? this.outbound,
      rawConfig: rawConfig ?? this.rawConfig,
      subscriptionExpiresAt:
          subscriptionExpiresAt ?? this.subscriptionExpiresAt,
      subscriptionSource: subscriptionSource ?? this.subscriptionSource,
      countryCode: countryCode ?? this.countryCode,
      countryName: countryName ?? this.countryName,
    );
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
