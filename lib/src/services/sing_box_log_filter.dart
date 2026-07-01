class SingBoxLogFilter {
  const SingBoxLogFilter._();

  static bool isDiagnosticNoise(String log) {
    return log.contains('router: found package name:') ||
        log.contains('router: found user id:') ||
        log.contains('router: failed to search process: process not found') ||
        log.contains('outbound/vless[proxy]: Xtls Unpadding') ||
        log.contains('outbound/vless[proxy]: XtlsPadding') ||
        log.contains('outbound/vless[proxy]: XtlsFilterTls');
  }
}
