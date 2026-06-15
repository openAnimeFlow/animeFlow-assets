// 检查 Bangumi Archive 更新，过滤 subject.jsonlines（仅 type=2 动画），
// 上传到 GitHub Releases 并更新 archive/latest.json。
//
// 运行：dart archive/script/update_archive.dart
//
// 环境变量：
//   GITHUB_TOKEN      — GitHub API 令牌（CI 中自动注入）
//   GITHUB_REPOSITORY — owner/repo（CI 中自动注入）

import 'dart:convert';
import 'dart:io';

const _bangumiLatestUrl =
    'https://raw.githubusercontent.com/bangumi/Archive/master/aux/latest.json';
const _releaseTag = 'bangumi-anime-subject';
const _assetName = 'subject.jsonlines';

void main() async {
  final archiveRoot =
      File(Platform.script.toFilePath()).parent.parent.absolute;
  final latestFile = File(
    '${archiveRoot.path}${Platform.pathSeparator}latest.json',
  );

  final remote = await _fetchJson(_bangumiLatestUrl);
  final local = _readLocalLatest(latestFile);

  final remoteUpdatedAt = _parseDate(remote['updated_at'] as String?);
  final localUpdatedAt = _parseDate(
    local?['source_updated_at'] as String? ??
        local?['updated_at'] as String?,
  );

  if (remoteUpdatedAt != null &&
      localUpdatedAt != null &&
      !remoteUpdatedAt.isAfter(localUpdatedAt)) {
    stdout.writeln(
      'No update needed: remote updated_at=${remote['updated_at']}, '
      'local=${local?['source_updated_at'] ?? local?['updated_at']}',
    );
    exit(0);
  }

  stdout.writeln('New archive detected: ${remote['name']}');

  final tempDir = await Directory.systemTemp.createTemp('bangumi-archive-');
  try {
    final zipPath =
        '${tempDir.path}${Platform.pathSeparator}archive.zip';
    await _downloadFile(
      remote['browser_download_url'] as String,
      zipPath,
    );

    final dumpName = (remote['name'] as String).replaceAll('.zip', '');
    final zipEntry = await _findSubjectEntry(zipPath, dumpName);

    final filteredPath =
        '${tempDir.path}${Platform.pathSeparator}$_assetName';
    await _filterSubjectJsonlines(zipPath, zipEntry, filteredPath);

    final filteredFile = File(filteredPath);
    final assetInfo = await _uploadToRelease(filteredFile);

    await _writeLatestJson(
      latestFile,
      remote: remote,
      assetUrl: assetInfo['browser_download_url'] as String,
      size: assetInfo['size'] as int,
    );

    stdout.writeln('Archive update completed.');
  } finally {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  }
}

Map<String, dynamic>? _readLocalLatest(File latestFile) {
  if (!latestFile.existsSync() || latestFile.lengthSync() == 0) {
    return null;
  }
  try {
    return jsonDecode(latestFile.readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

DateTime? _parseDate(String? value) {
  if (value == null || value.isEmpty) return null;
  return DateTime.tryParse(value);
}

Future<Map<String, dynamic>> _fetchJson(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      stderr.writeln('Failed to fetch $url: HTTP ${response.statusCode}');
      exit(1);
    }
    final body = await response.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

Future<void> _downloadFile(String url, String destPath) async {
  stdout.writeln('Downloading $url ...');
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      stderr.writeln('Download failed: HTTP ${response.statusCode}');
      exit(1);
    }
    final file = File(destPath);
    final sink = file.openWrite();
    await response.pipe(sink);
    await sink.close();
    stdout.writeln('Downloaded ${file.lengthSync()} bytes');
  } finally {
    client.close(force: true);
  }
}

/// 在 zip 中定位 subject.jsonlines 条目路径。
Future<String> _findSubjectEntry(String zipPath, String dumpName) async {
  final expected = '$dumpName/subject.jsonlines';

  final List<String> entries;
  if (Platform.isWindows) {
    final result = await Process.run('tar', ['-tf', zipPath]);
    if (result.exitCode != 0) {
      stderr.writeln('tar -tf failed: ${result.stderr}');
      exit(1);
    }
    entries = (result.stdout as String)
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  } else {
    final result = await Process.run('unzip', ['-Z1', zipPath]);
    if (result.exitCode != 0) {
      stderr.writeln('unzip -Z1 failed: ${result.stderr}');
      exit(1);
    }
    entries = (result.stdout as String)
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  if (entries.contains(expected)) return expected;

  final match = entries.where((e) => e.endsWith('subject.jsonlines')).toList();
  if (match.length == 1) return match.first;

  stderr.writeln(
    'Cannot find subject.jsonlines in zip (expected $expected)',
  );
  exit(1);
}

/// 启动解压进程，将 zip 内指定条目输出到 stdout。
Future<Process> _startZipExtract(String zipPath, String zipEntry) async {
  if (Platform.isWindows) {
    return Process.start('tar', ['-xOf', zipPath, zipEntry]);
  }
  return Process.start('unzip', ['-p', zipPath, zipEntry]);
}

/// 流式解压并过滤 subject.jsonlines，仅保留 type == 2（动画）。
Future<void> _filterSubjectJsonlines(
  String zipPath,
  String zipEntry,
  String outputPath,
) async {
  stdout.writeln('Filtering $zipEntry (type == 2) ...');

  final unzip = await _startZipExtract(zipPath, zipEntry);
  final stderrBuffer = <int>[];
  unzip.stderr.listen(stderrBuffer.addAll);

  final output = File(outputPath).openWrite();
  var total = 0;
  var kept = 0;

  try {
    final lines = unzip.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      if (line.isEmpty) continue;
      total++;
      final obj = jsonDecode(line) as Map<String, dynamic>;
      if (obj['type'] == 2) {
        output.writeln(line);
        kept++;
      }
      if (total % 100000 == 0) {
        stdout.writeln('  processed $total lines, kept $kept');
      }
    }

    final exitCode = await unzip.exitCode;
    if (exitCode != 0) {
      stderr.writeln(
        'zip extract failed (exit $exitCode): '
        '${utf8.decode(stderrBuffer)}',
      );
      exit(1);
    }
  } finally {
    await output.close();
  }

  stdout.writeln(
    'Filtered $kept / $total lines -> ${File(outputPath).lengthSync()} bytes',
  );
}

Future<Map<String, dynamic>> _uploadToRelease(File file) async {
  final token = Platform.environment['GITHUB_TOKEN'];
  final repository = Platform.environment['GITHUB_REPOSITORY'];

  if (token == null || token.isEmpty) {
    stderr.writeln('GITHUB_TOKEN is required for release upload');
    exit(1);
  }
  if (repository == null || repository.isEmpty) {
    stderr.writeln('GITHUB_REPOSITORY is required for release upload');
    exit(1);
  }

  final release = await _ensureRelease(token, repository);
  final releaseId = release['id'] as int;

  await _deleteExistingAsset(token, repository, release);

  stdout.writeln('Uploading $_assetName to release $_releaseTag ...');
  final uploadUrl =
      'https://uploads.github.com/repos/$repository/releases/$releaseId/assets?name=$_assetName';

  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(uploadUrl));
    request.headers.set('Authorization', 'Bearer $token');
    request.headers.set('Content-Type', 'application/octet-stream');
    request.headers.set('Accept', 'application/vnd.github+json');
    request.contentLength = file.lengthSync();
    await request.addStream(file.openRead());
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    if (response.statusCode != 201) {
      stderr.writeln(
        'Upload failed: HTTP ${response.statusCode} $body',
      );
      exit(1);
    }

    final asset = jsonDecode(body) as Map<String, dynamic>;
    stdout.writeln('Uploaded: ${asset['browser_download_url']}');
    return asset;
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> _ensureRelease(
  String token,
  String repository,
) async {
  final existing = await _apiGet(
    token,
    'https://api.github.com/repos/$repository/releases/tags/$_releaseTag',
  );

  if (existing != null) {
    stdout.writeln('Release $_releaseTag already exists (id=${existing['id']})');
    return existing;
  }

  stdout.writeln('Creating release $_releaseTag ...');
  final created = await _apiPost(
    token,
    'https://api.github.com/repos/$repository/releases',
    {
      'tag_name': _releaseTag,
      'name': 'Bangumi Anime Subject Archive',
      'body':
          'Filtered Bangumi subject data (type=2 anime only). '
          'Source: https://github.com/bangumi/Archive',
      'draft': false,
      'prerelease': false,
    },
  );

  if (created == null) {
    stderr.writeln('Failed to create release');
    exit(1);
  }
  return created;
}

Future<void> _deleteExistingAsset(
  String token,
  String repository,
  Map<String, dynamic> release,
) async {
  final assets = release['assets'] as List<dynamic>? ?? [];
  for (final asset in assets) {
    final map = asset as Map<String, dynamic>;
    if (map['name'] == _assetName) {
      final assetId = map['id'];
      stdout.writeln('Deleting existing asset id=$assetId ...');
      await _apiDelete(
        token,
        'https://api.github.com/repos/$repository/releases/assets/$assetId',
      );
    }
  }
}

Future<Map<String, dynamic>?> _apiGet(String token, String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('Authorization', 'Bearer $token');
    request.headers.set('Accept', 'application/vnd.github+json');
    request.headers.set('User-Agent', 'animeFlow-assets-archive-script');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      stderr.writeln('GET $url failed: HTTP ${response.statusCode} $body');
      exit(1);
    }
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>?> _apiPost(
  String token,
  String url,
  Map<String, dynamic> data,
) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(url));
    request.headers.set('Authorization', 'Bearer $token');
    request.headers.set('Accept', 'application/vnd.github+json');
    request.headers.set('Content-Type', 'application/json');
    request.headers.set('User-Agent', 'animeFlow-assets-archive-script');
    request.write(jsonEncode(data));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 201) {
      stderr.writeln('POST $url failed: HTTP ${response.statusCode} $body');
      return null;
    }
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

Future<void> _apiDelete(String token, String url) async {
  final client = HttpClient();
  try {
    final request = await client.deleteUrl(Uri.parse(url));
    request.headers.set('Authorization', 'Bearer $token');
    request.headers.set('Accept', 'application/vnd.github+json');
    request.headers.set('User-Agent', 'animeFlow-assets-archive-script');
    final response = await request.close();
    if (response.statusCode != 204) {
      final body = await response.transform(utf8.decoder).join();
      stderr.writeln('DELETE $url failed: HTTP ${response.statusCode} $body');
      exit(1);
    }
  } finally {
    client.close(force: true);
  }
}

Future<void> _writeLatestJson(
  File latestFile,
  {
  required Map<String, dynamic> remote,
  required String assetUrl,
  required int size,
}) async {
  final now = DateTime.now().toUtc();
  final content = {
    'source_updated_at': remote['updated_at'],
    'source_digest': remote['digest'],
    'source_name': remote['name'],
    'browser_download_url': assetUrl,
    'name': _assetName,
    'content_type': 'application/json',
    'size': size,
    'updated_at': now.toIso8601String(),
  };

  final encoded =
      '${const JsonEncoder.withIndent('  ').convert(content)}\n';
  latestFile.writeAsStringSync(encoded);
  stdout.writeln('Updated ${latestFile.path}');
}
