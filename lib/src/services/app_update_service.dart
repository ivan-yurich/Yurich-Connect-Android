import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

const _releaseApiUrls = [
  'https://ivan-it.net/yurich-connect/android/latest.json',
  'https://api.github.com/repos/ivan-yurich/Yurich-Connect-Android/releases/latest',
];
const _githubRepository = 'ivan-yurich/Yurich-Connect-Android';
const _githubReleaseAssetName = 'YurichConnect-android-release.apk';
const _updaterUserAgent = 'YurichConnect-Updater';
const _updateRetryDelays = [
  Duration(seconds: 1),
  Duration(seconds: 3),
  Duration(seconds: 6),
];

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.version,
    required this.assetName,
    required this.downloadUrl,
    required this.size,
    this.fallbackDownloadUrls = const [],
  });

  final String version;
  final String assetName;
  final Uri downloadUrl;
  final int? size;
  final List<Uri> fallbackDownloadUrls;
}

class _UpdateHttpException implements Exception {
  const _UpdateHttpException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'HTTP $statusCode';
}

class AppUpdatePermissionException implements Exception {
  const AppUpdatePermissionException();

  @override
  String toString() => 'Install permission is required.';
}

class AppUpdateService {
  AppUpdateService({HttpClient? client, List<Uri>? releaseApiUris})
    : _client = client ?? HttpClient(),
      _releaseApiUris =
          releaseApiUris ??
          _releaseApiUrls.map(Uri.parse).toList(growable: false) {
    _client.connectionTimeout = const Duration(seconds: 7);
  }

  static const _channel = MethodChannel('online.dnsai.ivanvpn/updater');

  static Uri get latestApkDownloadUri => Uri.parse(
    'https://github.com/$_githubRepository/releases/latest/download/'
    '$_githubReleaseAssetName',
  );

  final HttpClient _client;
  final List<Uri> _releaseApiUris;

  Future<List<String>> supportedAbis() async {
    if (!Platform.isAndroid) {
      return const [];
    }
    final value = await _channel.invokeMethod<List<Object?>>(
      'getSupportedAbis',
    );
    return value?.whereType<String>().toList(growable: false) ?? const [];
  }

  Future<AppUpdateInfo?> findLatest({
    required String currentVersion,
    required List<String> supportedAbis,
  }) async {
    Object? lastError;
    var sawEmptyEndpoint = false;
    var sawNotNewerRelease = false;
    for (final uri in _releaseApiUris) {
      try {
        final release = await _fetchRelease(uri, supportedAbis);
        if (release == null) {
          sawEmptyEndpoint = true;
          continue;
        }
        if (_isVersionNewer(release.version, currentVersion)) {
          return release;
        }
        sawNotNewerRelease = true;
      } on Object catch (error) {
        lastError = error;
      }
    }

    try {
      final release = await _fetchLatestGitHubReleaseViaRedirect(supportedAbis);
      if (release != null) {
        if (_isVersionNewer(release.version, currentVersion)) {
          return release;
        }
        sawNotNewerRelease = true;
      }
    } on Object catch (error) {
      lastError = error;
    }

    if (lastError != null && !sawEmptyEndpoint && !sawNotNewerRelease) {
      throw StateError('$lastError');
    }
    return null;
  }

  Future<File> download(
    AppUpdateInfo update, {
    required void Function(double? progress) onProgress,
  }) async {
    final tempDir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'yurich_connect_updates',
    );
    if (!await tempDir.exists()) {
      await tempDir.create(recursive: true);
    }
    final file = File(
      '${tempDir.path}${Platform.pathSeparator}${update.assetName}',
    );
    if (await _isCompleteDownloadedFile(file, update.size)) {
      onProgress(1);
      return file;
    }

    Object? lastError;
    final urls = <Uri>{
      update.downloadUrl,
      ...update.fallbackDownloadUrls,
      ..._githubDownloadUrls(update.version, update.assetName),
    }.toList(growable: false);

    for (final url in urls) {
      for (var attempt = 0; attempt < _updateRetryDelays.length; attempt += 1) {
        try {
          await _downloadToFile(update, url, file, onProgress);
          return file;
        } on Object catch (error) {
          lastError = error;
          if (await file.exists()) {
            await file.delete();
          }
          if (!_shouldRetryUpdateError(error) ||
              attempt == _updateRetryDelays.length - 1) {
            break;
          }
          await Future<void>.delayed(_updateRetryDelays[attempt]);
        }
      }
    }

    throw StateError('$lastError');
  }

  Future<void> _downloadToFile(
    AppUpdateInfo update,
    Uri url,
    File file,
    void Function(double? progress) onProgress,
  ) async {
    final request = await _client.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, _updaterUserAgent);
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.android.package-archive, application/octet-stream, */*',
    );
    request.followRedirects = true;
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>();
      throw _UpdateHttpException(response.statusCode);
    }

    final sink = file.openWrite();
    var received = 0;
    final total = response.contentLength > 0
        ? response.contentLength
        : update.size;
    try {
      await for (final chunk in response) {
        received += chunk.length;
        sink.add(chunk);
        if (total != null && total > 0) {
          onProgress((received / total).clamp(0, 1).toDouble());
        } else {
          onProgress(null);
        }
      }
    } finally {
      await sink.close();
    }
    onProgress(1);

    final expectedSize = update.size;
    if (expectedSize != null && expectedSize > 0) {
      final actualSize = await file.length();
      if (actualSize != expectedSize) {
        throw StateError(
          'APK size mismatch: expected $expectedSize bytes, got $actualSize.',
        );
      }
    }
  }

  Future<bool> _isCompleteDownloadedFile(File file, int? expectedSize) async {
    if (!await file.exists()) {
      return false;
    }
    final actualSize = await file.length();
    if (actualSize <= 0) {
      return false;
    }
    return expectedSize == null ||
        expectedSize <= 0 ||
        actualSize == expectedSize;
  }

  Future<void> installApk(File file) async {
    try {
      await _channel.invokeMethod<void>('installApk', {'path': file.path});
    } on PlatformException catch (error) {
      if (error.code == 'INSTALL_PERMISSION') {
        throw const AppUpdatePermissionException();
      }
      rethrow;
    }
  }

  Future<void> openInstallSettings() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('openInstallSettings');
    }
  }

  Future<AppUpdateInfo?> _fetchRelease(
    Uri uri,
    List<String> supportedAbis,
  ) async {
    final json = await _fetchReleaseJson(uri);
    if (json == null) {
      return null;
    }
    final version = (json['version'] ?? json['tag_name'] ?? json['name'] ?? '')
        .toString();
    if (version.trim().isEmpty) {
      throw StateError('Update endpoint has no version.');
    }

    final assets = (json['assets'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList(growable: false);
    final selected = _selectAsset(assets, supportedAbis);
    if (selected == null) {
      return null;
    }

    final downloadUrl =
        (selected['download_url'] ?? selected['browser_download_url'] ?? '')
            .toString();
    if (downloadUrl.isEmpty) {
      throw StateError('Update asset has no download URL.');
    }

    return AppUpdateInfo(
      version: _normalizeVersion(version),
      assetName: selected['name']?.toString() ?? 'YurichConnect-update.apk',
      downloadUrl: Uri.parse(downloadUrl),
      fallbackDownloadUrls: _githubDownloadUrls(
        _normalizeVersion(version),
        selected['name']?.toString() ?? _githubReleaseAssetName,
      ),
      size: selected['size'] is int ? selected['size'] as int : null,
    );
  }

  Future<Map<String, dynamic>?> _fetchReleaseJson(Uri uri) async {
    Object? lastError;
    for (var attempt = 0; attempt < _updateRetryDelays.length; attempt += 1) {
      try {
        final request = await _client.getUrl(uri);
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        request.headers.set(HttpHeaders.userAgentHeader, _updaterUserAgent);
        request.followRedirects = true;
        final response = await request.close().timeout(
          const Duration(seconds: 14),
        );
        if (response.statusCode == HttpStatus.notFound) {
          await response.drain<void>();
          return null;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.drain<void>();
          throw _UpdateHttpException(response.statusCode);
        }

        final raw = await utf8.decodeStream(response);
        return jsonDecode(raw) as Map<String, dynamic>;
      } on Object catch (error) {
        lastError = error;
        if (!_shouldRetryUpdateError(error) ||
            attempt == _updateRetryDelays.length - 1) {
          break;
        }
        await Future<void>.delayed(_updateRetryDelays[attempt]);
      }
    }

    throw StateError('$lastError');
  }

  Future<AppUpdateInfo?> _fetchLatestGitHubReleaseViaRedirect(
    List<String> supportedAbis,
  ) async {
    final tag = await _fetchLatestGitHubTag();
    if (tag == null || tag.trim().isEmpty) {
      return null;
    }

    for (final assetName in _githubAssetNameCandidates(tag, supportedAbis)) {
      final urls = _githubDownloadUrls(tag, assetName);
      final size = await _tryFetchContentLength(urls.first);
      if (size == null && assetName != _githubReleaseAssetName) {
        continue;
      }
      return AppUpdateInfo(
        version: _normalizeVersion(tag),
        assetName: assetName,
        downloadUrl: urls.first,
        fallbackDownloadUrls: urls.skip(1).toList(growable: false),
        size: size,
      );
    }

    return null;
  }

  Future<String?> _fetchLatestGitHubTag() async {
    Object? lastError;
    final uri = Uri.parse(
      'https://github.com/$_githubRepository/releases/latest',
    );
    for (var attempt = 0; attempt < _updateRetryDelays.length; attempt += 1) {
      try {
        final request = await _client.getUrl(uri);
        request.headers.set(HttpHeaders.userAgentHeader, _updaterUserAgent);
        request.followRedirects = false;
        final response = await request.close().timeout(
          const Duration(seconds: 14),
        );
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();

        final resolved = location == null ? uri : uri.resolve(location);
        final tag = _tagFromGitHubReleaseUri(resolved);
        if (tag != null) {
          return tag;
        }

        if (response.statusCode < 200 || response.statusCode >= 400) {
          throw _UpdateHttpException(response.statusCode);
        }
        return null;
      } on Object catch (error) {
        lastError = error;
        if (!_shouldRetryUpdateError(error) ||
            attempt == _updateRetryDelays.length - 1) {
          break;
        }
        await Future<void>.delayed(_updateRetryDelays[attempt]);
      }
    }

    throw StateError('$lastError');
  }

  String? _tagFromGitHubReleaseUri(Uri uri) {
    final segments = uri.pathSegments;
    final tagIndex = segments.indexOf('tag');
    if (tagIndex < 0 || tagIndex + 1 >= segments.length) {
      return null;
    }
    return segments[tagIndex + 1];
  }

  Future<int?> _tryFetchContentLength(Uri uri) async {
    try {
      final request = await _client.headUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, _updaterUserAgent);
      request.followRedirects = true;
      final response = await request.close().timeout(
        const Duration(seconds: 14),
      );
      final length = response.contentLength;
      await response.drain<void>();
      return length > 0 ? length : null;
    } on Object {
      return null;
    }
  }

  List<Uri> _githubDownloadUrls(String version, String assetName) {
    final normalized = _normalizeVersion(version);
    final tag = normalized.startsWith('v') ? normalized : 'v$normalized';
    return [
      Uri.parse(
        'https://github.com/$_githubRepository/releases/download/$tag/$assetName',
      ),
      Uri.parse(
        'https://github.com/$_githubRepository/releases/latest/download/$assetName',
      ),
    ];
  }

  List<String> _githubAssetNameCandidates(
    String version,
    List<String> supportedAbis,
  ) {
    final normalized = _normalizeVersion(version);
    return [
      if (supportedAbis.contains('arm64-v8a'))
        'YurichConnect-android-arm64-v8a-v$normalized.apk',
      if (supportedAbis.contains('armeabi-v7a'))
        'YurichConnect-android-armeabi-v7a-v$normalized.apk',
      if (supportedAbis.contains('x86_64'))
        'YurichConnect-android-x86_64-v$normalized.apk',
      _githubReleaseAssetName,
    ];
  }

  bool _shouldRetryUpdateError(Object error) {
    if (error is TimeoutException || error is SocketException) {
      return true;
    }
    if (error is _UpdateHttpException) {
      return error.statusCode == HttpStatus.requestTimeout ||
          error.statusCode == 429 ||
          error.statusCode >= 500;
    }
    final text = '$error';
    return text.contains('HTTP 408') ||
        text.contains('HTTP 429') ||
        RegExp(r'HTTP 5\d\d').hasMatch(text);
  }

  Map<String, dynamic>? _selectAsset(
    List<Map<String, dynamic>> assets,
    List<String> supportedAbis,
  ) {
    final apks = assets
        .where((asset) {
          final name = asset['name']?.toString().toLowerCase() ?? '';
          return name.endsWith('.apk');
        })
        .toList(growable: false);
    if (apks.isEmpty) {
      return null;
    }

    final priorities = <String>[
      if (supportedAbis.contains('arm64-v8a')) 'arm64-v8a',
      if (supportedAbis.contains('armeabi-v7a')) 'armeabi-v7a',
      if (supportedAbis.contains('x86_64')) 'x86_64',
      'universal',
      'release',
    ];

    for (final priority in priorities) {
      for (final asset in apks) {
        final name = asset['name']?.toString().toLowerCase() ?? '';
        if (name.contains(priority)) {
          return asset;
        }
      }
    }

    return apks.first;
  }

  bool _isVersionNewer(String remote, String current) {
    final remoteParts = _versionParts(remote);
    final currentParts = _versionParts(current);
    final maxLength = remoteParts.length > currentParts.length
        ? remoteParts.length
        : currentParts.length;
    for (var i = 0; i < maxLength; i += 1) {
      final remotePart = i < remoteParts.length ? remoteParts[i] : 0;
      final currentPart = i < currentParts.length ? currentParts[i] : 0;
      if (remotePart != currentPart) {
        return remotePart > currentPart;
      }
    }
    return false;
  }

  List<int> _versionParts(String value) => _normalizeVersion(
    value,
  ).split('.').map((part) => int.tryParse(part) ?? 0).toList(growable: false);

  String _normalizeVersion(String value) {
    final match = RegExp(r'\d+(?:\.\d+)*').firstMatch(value);
    return match?.group(0) ?? value.replaceFirst(RegExp(r'^[vV]'), '');
  }
}
