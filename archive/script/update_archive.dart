// 检查 Bangumi Archive 更新，解压全部 jsonlines 文件，
// 清洗 subject.jsonlines（仅 type=2 动画），
// 清洗 episode.jsonlines、subject-persons.jsonlines（仅保留 subject 中存在的 subject_id），
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
const _subjectAssetName = 'subject.jsonlines';
const _episodeAssetName = 'episode.jsonlines';
const _subjectPersonsAssetName = 'subject-persons.jsonlines';
const _retentionDays = 365;
final _dumpDatePattern = RegExp(r'^dump-(\d{4})-(\d{2})-(\d{2})');

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
    final extractDir = Directory(
      '${tempDir.path}${Platform.pathSeparator}extract',
    );
    extractDir.createSync();
    await _extractZip(zipPath, extractDir.path);

    final subjectFile = File(
      '${extractDir.path}${Platform.pathSeparator}$_subjectAssetName',
    );
    if (!subjectFile.existsSync()) {
      stderr.writeln('subject.jsonlines not found in ${extractDir.path}');
      exit(1);
    }

    final keptSubjectIds = await _filterSubjectJsonlinesFile(subjectFile.path);

    await _filterJsonlinesBySubjectIdIfExists(
      extractDir,
      _episodeAssetName,
      keptSubjectIds,
    );
    await _filterJsonlinesBySubjectIdIfExists(
      extractDir,
      _subjectPersonsAssetName,
      keptSubjectIds,
    );

    final files = _collectJsonlinesFiles(extractDir);
    stdout.writeln('Uploading ${files.length} file(s) to release ...');
    final assets = await _uploadFilesToRelease(files, dumpName);

    await _writeLatestJson(
      latestFile,
      remote: remote,
      dumpName: dumpName,
      assets: assets,
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

/// 将 zip 解压到目标目录（写入磁盘，不占用大量内存）。
Future<void> _extractZip(String zipPath, String destDir) async {
  stdout.writeln('Extracting zip to $destDir ...');

  final ProcessResult result;
  if (Platform.isWindows) {
    result = await Process.run('tar', ['-xf', zipPath, '-C', destDir]);
  } else {
    result = await Process.run('unzip', ['-q', zipPath, '-d', destDir]);
  }

  if (result.exitCode != 0) {
    stderr.writeln('Extract failed: ${result.stderr}');
    exit(1);
  }
}

List<File> _collectJsonlinesFiles(Directory dir) {
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => _basename(f.path).endsWith('.jsonlines'))
      .toList();
  files.sort((a, b) => _basename(a.path).compareTo(_basename(b.path)));
  return files;
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments = normalized.split('/').where((s) => s.isNotEmpty);
  return segments.isEmpty ? path : segments.last;
}

String _buildAssetName(String dumpName, String fileName) => '$dumpName-$fileName';

/// 从 Release 资源名（如 dump-2026-06-09.210424Z-subject.jsonlines）解析 dump 日期。
DateTime? _parseDumpDateFromAssetName(String assetName) {
  final match = _dumpDatePattern.firstMatch(assetName);
  if (match == null) return null;
  return DateTime.utc(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}

/// 判断是否应删除该 Release 资源。
/// 保留近 [_retentionDays] 天内的版本化资源；删除过期、旧版无前缀、当前 dump 重复项。
String? _assetDeleteReason(String name, String dumpName, DateTime cutoffUtc) {
  if (name.startsWith('$dumpName-')) return 'current dump re-upload';

  final dumpDate = _parseDumpDateFromAssetName(name);
  if (dumpDate == null) return 'legacy unversioned name';

  if (dumpDate.isBefore(cutoffUtc)) {
    return 'older than $_retentionDays days';
  }
  return null;
}

/// 流式过滤 subject.jsonlines，仅保留 type == 2（动画），原地替换。
/// 返回保留条目的 subject id 集合，供关联表过滤使用。
Future<Set<int>> _filterSubjectJsonlinesFile(String subjectPath) async {
  stdout.writeln('Filtering $_subjectAssetName (type == 2) ...');

  final input = File(subjectPath);
  final tempPath = '$subjectPath.filtered';
  final output = File(tempPath).openWrite();
  final keptIds = <int>{};
  var total = 0;
  var kept = 0;

  try {
    final lines = input
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      if (line.isEmpty) continue;
      total++;
      final obj = jsonDecode(line) as Map<String, dynamic>;
      if (obj['type'] == 2) {
        output.writeln(line);
        kept++;
        final id = obj['id'];
        if (id is int) keptIds.add(id);
      }
      if (total % 100000 == 0) {
        stdout.writeln('  processed $total lines, kept $kept');
      }
    }
  } finally {
    await output.close();
  }

  input.deleteSync();
  File(tempPath).renameSync(subjectPath);

  stdout.writeln(
    'Filtered $kept / $total lines -> ${File(subjectPath).lengthSync()} bytes',
  );
  return keptIds;
}

Future<void> _filterJsonlinesBySubjectIdIfExists(
  Directory extractDir,
  String assetName,
  Set<int> subjectIds,
) async {
  final file = File(
    '${extractDir.path}${Platform.pathSeparator}$assetName',
  );
  if (!file.existsSync()) {
    stdout.writeln('$assetName not found, skipping filter');
    return;
  }
  await _filterJsonlinesBySubjectId(file.path, subjectIds, assetName);
}

/// 流式过滤 jsonlines，仅保留 subject_id 在 [subjectIds] 中的条目。
Future<void> _filterJsonlinesBySubjectId(
  String filePath,
  Set<int> subjectIds,
  String assetName,
) async {
  stdout.writeln(
    'Filtering $assetName (subject_id in ${subjectIds.length} subjects) ...',
  );

  final input = File(filePath);
  final tempPath = '$filePath.filtered';
  final output = File(tempPath).openWrite();
  var total = 0;
  var kept = 0;

  try {
    final lines = input
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      if (line.isEmpty) continue;
      total++;
      final obj = jsonDecode(line) as Map<String, dynamic>;
      final subjectId = obj['subject_id'];
      if (subjectId is int && subjectIds.contains(subjectId)) {
        output.writeln(line);
        kept++;
      }
      if (total % 100000 == 0) {
        stdout.writeln('  processed $total lines, kept $kept');
      }
    }
  } finally {
    await output.close();
  }

  input.deleteSync();
  File(tempPath).renameSync(filePath);

  stdout.writeln(
    'Filtered $kept / $total lines -> ${File(filePath).lengthSync()} bytes',
  );
}

Future<List<Map<String, dynamic>>> _uploadFilesToRelease(
  List<File> files,
  String dumpName,
) async {
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

  await _deleteStaleAssets(token, repository, release, dumpName);

  final uploaded = <Map<String, dynamic>>[];
  for (final file in files) {
    final fileName = _basename(file.path);
    final assetName = _buildAssetName(dumpName, fileName);
    stdout.writeln('Uploading $assetName ...');
    final asset = await _uploadAsset(
      token,
      repository,
      releaseId,
      file,
      assetName,
    );
    uploaded.add(asset);
    stdout.writeln('  -> ${asset['browser_download_url']}');
  }
  return uploaded;
}

Future<Map<String, dynamic>> _uploadAsset(
  String token,
  String repository,
  int releaseId,
  File file,
  String assetName,
) async {
  final uploadUrl = Uri(
    scheme: 'https',
    host: 'uploads.github.com',
    path: '/repos/$repository/releases/$releaseId/assets',
    queryParameters: {'name': assetName},
  );

  final client = HttpClient();
  try {
    final request = await client.postUrl(uploadUrl);
    request.headers.set('Authorization', 'Bearer $token');
    request.headers.set('Content-Type', 'application/octet-stream');
    request.headers.set('Accept', 'application/vnd.github+json');
    request.contentLength = file.lengthSync();
    await request.addStream(file.openRead());
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    if (response.statusCode != 201) {
      stderr.writeln(
        'Upload $assetName failed: HTTP ${response.statusCode} $body',
      );
      exit(1);
    }

    return jsonDecode(body) as Map<String, dynamic>;
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
      'name': 'Bangumi Archive',
      'body':
          'Bangumi wiki archive dump. subject.jsonlines is filtered to anime (type=2); '
          'episode.jsonlines and subject-persons.jsonlines keep only rows whose subject_id exists in the filtered subjects. '
          'Assets are named as {dump}-{file}.jsonlines and retained for $_retentionDays days. '
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

/// 删除超过保留期的资源、旧版无版本前缀的资源，以及当前 dump 的重复资源。
Future<void> _deleteStaleAssets(
  String token,
  String repository,
  Map<String, dynamic> release,
  String dumpName,
) async {
  final cutoffUtc = DateTime.utc(
    DateTime.now().toUtc().year,
    DateTime.now().toUtc().month,
    DateTime.now().toUtc().day,
  ).subtract(const Duration(days: _retentionDays));

  final assets = release['assets'] as List<dynamic>? ?? [];
  var kept = 0;

  for (final asset in assets) {
    final map = asset as Map<String, dynamic>;
    final name = map['name'] as String;
    final assetId = map['id'];
    final reason = _assetDeleteReason(name, dumpName, cutoffUtc);

    if (reason == null) {
      kept++;
      continue;
    }

    stdout.writeln('Deleting asset $name ($reason, id=$assetId) ...');
    await _apiDelete(
      token,
      'https://api.github.com/repos/$repository/releases/assets/$assetId',
    );
  }

  stdout.writeln(
    'Retention: keeping $kept asset(s) within $_retentionDays days',
  );
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
  required String dumpName,
  required List<Map<String, dynamic>> assets,
}) async {
  final now = DateTime.now().toUtc();
  final subjectAssetName = _buildAssetName(dumpName, _subjectAssetName);

  final assetEntries = assets.map((asset) {
    return {
      'name': asset['name'],
      'browser_download_url': asset['browser_download_url'],
      'size': asset['size'],
      'content_type': asset['content_type'] ?? 'application/octet-stream',
    };
  }).toList();

  Map<String, dynamic>? subjectAsset;
  for (final asset in assets) {
    if (asset['name'] == subjectAssetName) {
      subjectAsset = asset;
      break;
    }
  }

  final content = {
    'source_updated_at': remote['updated_at'],
    'source_digest': remote['digest'],
    'source_name': remote['name'],
    'dump_name': dumpName,
    if (subjectAsset != null) ...{
      'browser_download_url': subjectAsset['browser_download_url'],
      'name': subjectAsset['name'],
      'content_type': subjectAsset['content_type'] ?? 'application/json',
      'size': subjectAsset['size'],
    },
    'assets': assetEntries,
    'updated_at': now.toIso8601String(),
  };

  final encoded =
      '${const JsonEncoder.withIndent('  ').convert(content)}\n';
  latestFile.writeAsStringSync(encoded);
  stdout.writeln('Updated ${latestFile.path}');
}
