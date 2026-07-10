enum ConnectionStatus {
  connected('Подключено'),
  idle('Ожидание'),
  networkChanging('Смена сети'),
  degraded('Нестабильно'),
  reconnecting('Переподключение'),
  failed('Сбой'),
  disconnected('Отключено'),
  connecting('Подключение...');

  const ConnectionStatus(this.displayName);

  final String displayName;
}
