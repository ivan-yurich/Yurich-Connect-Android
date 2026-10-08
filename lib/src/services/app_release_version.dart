final class AppReleaseVersion implements Comparable<AppReleaseVersion> {
  const AppReleaseVersion._(this.base, this.testDate, this.testNumber);

  final List<int> base;
  final int? testDate;
  final int? testNumber;

  bool get isTesting => testDate != null;

  String get value =>
      '${base.join('.')}${isTesting ? '-test.$testDate.$testNumber' : ''}';

  static AppReleaseVersion? tryParse(String value) {
    final match = RegExp(
      r'^[vV]?(\d+)\.(\d+)\.(\d+)(?:-test\.(\d{8})\.(\d+))?(?:\+\d+)?$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    final base = [for (var i = 1; i <= 3; i++) int.tryParse(match.group(i)!)];
    if (base.any((part) => part == null)) return null;
    final date = match.group(4);
    int? testDate;
    int? testNumber;
    if (date != null) {
      final year = int.parse(date.substring(0, 4));
      final month = int.parse(date.substring(4, 6));
      final day = int.parse(date.substring(6, 8));
      final calendarDate = DateTime.utc(year, month, day);
      testNumber = int.tryParse(match.group(5)!);
      if (year < 2000 ||
          calendarDate.year != year ||
          calendarDate.month != month ||
          calendarDate.day != day ||
          testNumber == null ||
          testNumber < 1) {
        return null;
      }
      testDate = int.parse(date);
    }
    return AppReleaseVersion._(
      List<int>.unmodifiable(base.cast<int>()),
      testDate,
      testNumber,
    );
  }

  @override
  int compareTo(AppReleaseVersion other) {
    for (var i = 0; i < base.length; i++) {
      final comparison = base[i].compareTo(other.base[i]);
      if (comparison != 0) return comparison;
    }
    if (isTesting != other.isTesting) return isTesting ? -1 : 1;
    if (!isTesting) return 0;
    final dateComparison = testDate!.compareTo(other.testDate!);
    return dateComparison != 0
        ? dateComparison
        : testNumber!.compareTo(other.testNumber!);
  }
}
