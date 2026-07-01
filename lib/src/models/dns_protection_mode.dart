enum DnsProtectionMode {
  stable('stable'),
  leakGuard('leak_guard');

  const DnsProtectionMode(this.storageValue);

  final String storageValue;

  bool get protectsAgainstLeaks => this == DnsProtectionMode.leakGuard;

  static DnsProtectionMode fromStorageValue(String? value) {
    return DnsProtectionMode.values.firstWhere(
      (mode) => mode.storageValue == value,
      orElse: () => DnsProtectionMode.stable,
    );
  }
}
