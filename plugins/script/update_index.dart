// 根据变更的插件 JSON 创建或更新 plugins/index.json。
//
// 运行：
//   dart plugins/script/update_index.dart
//
// CI 环境变量（空格分隔路径）：
//   PLUGIN_CHANGED_FILES、PLUGIN_DELETED_FILES

import 'dart:convert';
import 'dart:io';

void main() {
  final pluginsDir = File(Platform.script.toFilePath()).parent.parent;
  final indexFile = File('${pluginsDir.path}${Platform.pathSeparator}index.json');

  final changed = _pathsFromEnv('PLUGIN_CHANGED_FILES');
  final deleted = _pathsFromEnv('PLUGIN_DELETED_FILES');

  if (changed.isEmpty && deleted.isEmpty) {
    stdout.writeln('No plugin JSON files changed, skipping index.json update');
    return;
  }

  final indexExists = indexFile.existsSync();
  List<dynamic> index;
  if (indexExists) {
    index = jsonDecode(indexFile.readAsStringSync()) as List<dynamic>;
  } else {
    index = [];
    stdout.writeln('Created empty ${indexFile.path}');
  }

  var removed = 0;
  for (final file in deleted) {
    if (!_isPluginJsonPath(file)) continue;
    final path = _basename(file);
    final before = index.length;
    index = index
        .where((e) => e is Map && (e['path'] as String? ?? '') != path)
        .toList();
    if (index.length < before) {
      stdout.writeln('Removed index entry for deleted plugin: $path');
      removed++;
    }
  }

  final updateTime = '${DateTime.now().millisecondsSinceEpoch}';
  var updated = 0;

  for (final file in changed) {
    if (_isIndexJson(file) || !_isPluginJsonPath(file)) continue;

    if (!File(file).existsSync()) {
      stdout.writeln('File $file does not exist (deleted), already handled for index');
      continue;
    }

    final plugin =
        jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>;
    final path = _basename(file);
    final name = plugin['name'] as String? ?? '';
    final version = plugin['version'] as String? ?? '';
    final icon = plugin['iconUrl'] as String? ?? '';

    stdout.writeln('Updating index for: $file');
    stdout.writeln('   Name: $name');
    stdout.writeln('   Version: $version');
    stdout.writeln('   Icon: $icon');
    stdout.writeln('   Path: $path');
    stdout.writeln('   UpdateTime: $updateTime');

    final entry = {
      'name': name,
      'version': version,
      'icon': icon,
      'path': path,
      'updateTime': updateTime,
    };

    final idx = index.indexWhere(
      (e) => e is Map && (e['path'] as String? ?? '') == path,
    );

    if (idx >= 0) {
      stdout.writeln('   Updating existing entry for $path');
      index[idx] = entry;
    } else {
      stdout.writeln('   Adding new entry for $path');
      index.add(entry);
    }
    updated++;
    stdout.writeln('');
  }

  final content = '${const JsonEncoder.withIndent('  ').convert(index)}\n';
  if (indexExists) {
    indexFile.writeAsStringSync(content);
    stdout.writeln(
      'Updated index.json ($updated plugin(s) changed, $removed removed)',
    );
  } else {
    indexFile.createSync(recursive: true);
    indexFile.writeAsStringSync(content);
    stdout.writeln(
      'Created ${indexFile.path} ($updated plugin(s), $removed removed)',
    );
  }
}

List<String> _pathsFromEnv(String key) {
  final raw = Platform.environment[key];
  if (raw == null || raw.trim().isEmpty) return [];
  return raw.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
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
