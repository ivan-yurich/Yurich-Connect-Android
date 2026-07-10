import 'connection_status.dart';

class ConnectionUiState {
  const ConnectionUiState({
    required this.status,
    required this.uploadSpeed,
    required this.downloadSpeed,
    required this.totalTraffic,
    this.profileName,
    this.protocolDisplayName,
    this.countryName,
    this.countryCode,
    this.pingMs,
    this.sessionDuration,
  });

  final ConnectionStatus status;
  final String? profileName;
  final String? protocolDisplayName;
  final String? countryName;
  final String? countryCode;
  final int? pingMs;
  final String uploadSpeed;
  final String downloadSpeed;
  final String totalTraffic;
  final String? sessionDuration;

  factory ConnectionUiState.disconnected() {
    return const ConnectionUiState(
      status: ConnectionStatus.disconnected,
      uploadSpeed: '0 B/s',
      downloadSpeed: '0 B/s',
      totalTraffic: '0 B',
    );
  }

  factory ConnectionUiState.connecting({
    String? profileName,
    String? protocolDisplayName,
    String? countryName,
    String? countryCode,
    int? pingMs,
  }) {
    return ConnectionUiState(
      status: ConnectionStatus.connecting,
      profileName: profileName,
      protocolDisplayName: protocolDisplayName,
      countryName: countryName,
      countryCode: countryCode,
      pingMs: pingMs,
      uploadSpeed: '0 B/s',
      downloadSpeed: '0 B/s',
      totalTraffic: '0 B',
    );
  }

  factory ConnectionUiState.connected({
    required String uploadSpeed,
    required String downloadSpeed,
    required String totalTraffic,
    String? profileName,
    String? protocolDisplayName,
    String? countryName,
    String? countryCode,
    int? pingMs,
    String? sessionDuration,
  }) {
    return ConnectionUiState(
      status: ConnectionStatus.connected,
      profileName: profileName,
      protocolDisplayName: protocolDisplayName,
      countryName: countryName,
      countryCode: countryCode,
      pingMs: pingMs,
      uploadSpeed: uploadSpeed,
      downloadSpeed: downloadSpeed,
      totalTraffic: totalTraffic,
      sessionDuration: sessionDuration,
    );
  }

  factory ConnectionUiState.idle({
    required String uploadSpeed,
    required String downloadSpeed,
    required String totalTraffic,
    String? profileName,
    String? protocolDisplayName,
    String? countryName,
    String? countryCode,
    int? pingMs,
    String? sessionDuration,
  }) {
    return ConnectionUiState(
      status: ConnectionStatus.idle,
      profileName: profileName,
      protocolDisplayName: protocolDisplayName,
      countryName: countryName,
      countryCode: countryCode,
      pingMs: pingMs,
      uploadSpeed: uploadSpeed,
      downloadSpeed: downloadSpeed,
      totalTraffic: totalTraffic,
      sessionDuration: sessionDuration,
    );
  }

  factory ConnectionUiState.degraded({
    required String uploadSpeed,
    required String downloadSpeed,
    required String totalTraffic,
    String? profileName,
    String? protocolDisplayName,
    String? countryName,
    String? countryCode,
    int? pingMs,
    String? sessionDuration,
  }) {
    return ConnectionUiState(
      status: ConnectionStatus.degraded,
      profileName: profileName,
      protocolDisplayName: protocolDisplayName,
      countryName: countryName,
      countryCode: countryCode,
      pingMs: pingMs,
      uploadSpeed: uploadSpeed,
      downloadSpeed: downloadSpeed,
      totalTraffic: totalTraffic,
      sessionDuration: sessionDuration,
    );
  }

  factory ConnectionUiState.networkChanging({
    required String uploadSpeed,
    required String downloadSpeed,
    required String totalTraffic,
    String? profileName,
    String? protocolDisplayName,
    String? countryName,
    String? countryCode,
    int? pingMs,
    String? sessionDuration,
  }) {
    return ConnectionUiState(
      status: ConnectionStatus.networkChanging,
      profileName: profileName,
      protocolDisplayName: protocolDisplayName,
      countryName: countryName,
      countryCode: countryCode,
      pingMs: pingMs,
      uploadSpeed: uploadSpeed,
      downloadSpeed: downloadSpeed,
      totalTraffic: totalTraffic,
      sessionDuration: sessionDuration,
    );
  }

  factory ConnectionUiState.reconnecting({
    String? profileName,
    String? protocolDisplayName,
    String? countryName,
    String? countryCode,
    int? pingMs,
    String? sessionDuration,
  }) {
    return ConnectionUiState(
      status: ConnectionStatus.reconnecting,
      profileName: profileName,
      protocolDisplayName: protocolDisplayName,
      countryName: countryName,
      countryCode: countryCode,
      pingMs: pingMs,
      uploadSpeed: '0 B/s',
      downloadSpeed: '0 B/s',
      totalTraffic: '0 B',
      sessionDuration: sessionDuration,
    );
  }

  factory ConnectionUiState.failed({
    String? profileName,
    String? protocolDisplayName,
    String? countryName,
    String? countryCode,
    int? pingMs,
  }) {
    return ConnectionUiState(
      status: ConnectionStatus.failed,
      profileName: profileName,
      protocolDisplayName: protocolDisplayName,
      countryName: countryName,
      countryCode: countryCode,
      pingMs: pingMs,
      uploadSpeed: '0 B/s',
      downloadSpeed: '0 B/s',
      totalTraffic: '0 B',
    );
  }

  Map<String, Object?> toJson() {
    return {
      'status': status.name,
      'statusDisplayName': status.displayName,
      'profileName': profileName,
      'protocolDisplayName': protocolDisplayName,
      'countryName': countryName,
      'countryCode': countryCode,
      'pingMs': pingMs,
      'uploadSpeed': uploadSpeed,
      'downloadSpeed': downloadSpeed,
      'totalTraffic': totalTraffic,
      'sessionDuration': sessionDuration,
    };
  }
}
