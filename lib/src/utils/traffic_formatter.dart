class TrafficFormatter {
  const TrafficFormatter._();

  static String formatSpeed(int bytesPerSecond) {
    return '${formatBytes(bytesPerSecond)}/s';
  }

  static String formatBytes(int bytes) {
    final value = bytes < 0 ? 0 : bytes;
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var amount = value.toDouble();
    var unitIndex = 0;

    while (amount >= 1024 && unitIndex < units.length - 1) {
      amount /= 1024;
      unitIndex += 1;
    }

    if (unitIndex == 0) {
      return '$value ${units[unitIndex]}';
    }
    if (amount >= 100 || amount == amount.roundToDouble()) {
      return '${amount.round()} ${units[unitIndex]}';
    }
    return '${amount.toStringAsFixed(1)} ${units[unitIndex]}';
  }

  static String formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds < 0 ? 0 : duration.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    return [
      hours.toString().padLeft(2, '0'),
      minutes.toString().padLeft(2, '0'),
      seconds.toString().padLeft(2, '0'),
    ].join(':');
  }
}
