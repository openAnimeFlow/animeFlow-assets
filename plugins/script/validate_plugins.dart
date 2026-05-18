// 校验 plugins 目录下插件 JSON 的格式与必填字段。
//
// 运行：
//   dart plugins/script/validate_plugins.dart
//   dart plugins/script/validate_plugins.dart plugins/foo.json
//
// CI 可通过环境变量传入变更列表：
//   PLUGIN_CHANGED_FILES、PLUGIN_DELETED_FILES（空格分隔路径）

import 'dart:convert';
import 'dart:io';

import 'plugin_schema.dart';

void main(List<String> args) {
  final pluginsDir = _pluginsDir();
  final changed = _collectPaths(
    envKey: 'PLUGIN_CHANGED_FILES',
    args: args,
    pluginsDir: pluginsDir,
    pluginJsonOnly: true,
  );
  final deleted = _collectPaths(
    envKey: 'PLUGIN_DELETED_FILES',
    args: const [],
    pluginsDir: pluginsDir,
    pluginJsonOnly: true,
  );

  if (changed.isEmpty && deleted.isEmpty) {
    stdout.writeln('No plugin JSON files to validate, skipping');
    return;
  }

  stdout.writeln('Plugin JSON format requirements:');
  stdout.writeln('Required fields: ${requiredStringFields.join(', ')}');
  stdout.writeln('All required fields must be non-null strings');
  stdout.writeln('');

  final deletedSet = deleted.toSet();
  var anyFailed = false;

  for (final file in changed) {
    if (_isIndexJson(file)) {
      stdout.writeln('Skipping index.json validation: $file');
      stdout.writeln('');
      continue;
    }

    if (!_isPluginJsonPath(file)) continue;

    stdout.writeln('Validating: $file');

    if (!File(file).existsSync()) {
      if (deletedSet.contains(file)) {
        stdout.writeln('   File $file was deleted, skipping validation');
        stdout.writeln('');
        continue;
      }
      stderr.writeln('   Error: File $file does not exist');
      anyFailed = true;
      stdout.writeln('');
      continue;
    }

    final content = File(file).readAsStringSync();
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        stderr.writeln('   Error: $file root must be a JSON object');
        anyFailed = true;
        stdout.writeln('');
        continue;
      }
      json = decoded;
    } catch (e) {
      stderr.writeln('   Error: $file is not valid JSON');
      stderr.writeln('      $e');
      anyFailed = true;
      stdout.writeln('');
      continue;
    }

    final result = validatePluginJson(json, file);
    for (final w in result.warnings) {
      final msg = w.startsWith('$file: ') ? w.substring(file.length + 2) : w;
      stdout.writeln('   Warning: $msg');
    }
    for (final e in result.errors) {
      final msg = e.startsWith('$file: ') ? e.substring(file.length + 2) : e;
      stderr.writeln('   Error: $msg');
    }

    if (result.failed) {
      anyFailed = true;
    } else {
      stdout.writeln('   Validation passed');
    }
    stdout.writeln('');
  }

  if (anyFailed) {
    stderr.writeln('Validation failed! Please fix the errors above.');
    stderr.writeln('');
    stderr.writeln('Expected format:');
    stderr.writeln('{');
    for (final field in requiredStringFields) {
      stderr.writeln('  "$field": "<string value>"');
    }
    stderr.writeln('}');
    exit(1);
  }

  stdout.writeln('All JSON files validated successfully!');
  stdout.writeln('');
  stdout.writeln('All plugin JSON files match the required format specification.');
}

Directory _pluginsDir() {
  return File(Platform.script.toFilePath()).parent.parent;
}

List<String> _collectPaths({
  required String envKey,
  required List<String> args,
  required Directory pluginsDir,
  required bool pluginJsonOnly,
}) {
  final paths = <String>{};

  final fromEnv = Platform.environment[envKey];
  if (fromEnv != null && fromEnv.trim().isNotEmpty) {
    paths.addAll(fromEnv.split(RegExp(r'\s+')).where((p) => p.isNotEmpty));
  }

  for (final arg in args) {
    if (arg.startsWith('-')) continue;
    paths.add(arg);
  }

  if (paths.isEmpty && envKey == 'PLUGIN_CHANGED_FILES') {
    for (final entity in pluginsDir.listSync()) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      if (!name.endsWith('.json') || name == 'index.json') continue;
      paths.add(_repoRelativePath(entity, pluginsDir.parent));
    }
  }

  return paths
      .where((p) => !pluginJsonOnly || _isPluginJsonPath(p))
      .where((p) => !_isIndexJson(p) || envKey == 'PLUGIN_DELETED_FILES')
      .toList();
}

bool _isIndexJson(String path) => _basename(path) == 'index.json';

bool _isPluginJsonPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.startsWith('plugins/') &&
      normalized.endsWith('.json') &&
      !_isIndexJson(path);
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments = normalized.split('/').where((s) => s.isNotEmpty);
  return segments.isEmpty ? path : segments.last;
}

String _repoRelativePath(File file, Directory repoRoot) {
  final root = repoRoot.absolute.path;
  final full = file.absolute.path;
  if (!full.startsWith(root)) {
    return full.replaceAll('\\', '/');
  }
  var relative = full.substring(root.length);
  if (relative.startsWith(Platform.pathSeparator)) {
    relative = relative.substring(Platform.pathSeparator.length);
  } else if (relative.startsWith('/')) {
    relative = relative.substring(1);
  }
  return relative.replaceAll('\\', '/');
}
