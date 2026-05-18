// 扫描 fonts-repo/fonts 下各字体目录，根据 meta.json 与 .ttf 文件生成 index.json。
//
// 运行：dart fonts-repo/script/update_index.dart

import 'dart:convert';
import 'dart:io';

void main() {
  // 1. 定位 fonts-repo 根目录、fonts 目录与输出的 index.json
  final repoRoot = File(Platform.script.toFilePath()).parent.parent;
  final fontsDir = Directory('${repoRoot.path}${Platform.pathSeparator}fonts');
  final indexFile = File('${repoRoot.path}${Platform.pathSeparator}index.json');

  if (!fontsDir.existsSync()) {
    stderr.writeln('Fonts directory not found: ${fontsDir.path}');
    exit(1);
  }

  final entries = <Map<String, dynamic>>[];
  var hadError = false;

  // 2. 遍历 fonts 下的每个子文件夹
  for (final entity in fontsDir.listSync()) {
    if (entity is! Directory) continue;

    final folderName = entity.uri.pathSegments
        .where((s) => s.isNotEmpty)
        .last;

    // 3. 读取 meta.json，提取 id/family、name、author
    final metaFile = File(
      '${entity.path}${Platform.pathSeparator}meta.json',
    );

    if (!metaFile.existsSync()) {
      stderr.writeln('Skip $folderName: missing meta.json');
      continue;
    }

    final meta = jsonDecode(metaFile.readAsStringSync()) as Map<String, dynamic>;
    final id = _optionalString(meta, 'family');
    final name = _optionalString(meta, 'name');
    final author = _optionalString(meta, 'author');

    if (id == null || name == null || author == null) {
      stderr.writeln(
        'Skip $folderName: meta.json must include family, name, and author',
      );
      hadError = true;
      continue;
    }

    // 4. 收集目录内所有 .ttf 文件
    final ttfFiles = entity
        .listSync()
        .whereType<File>()
        .where((f) => _basename(f.path).toLowerCase().endsWith('.ttf'))
        .toList();

    if (ttfFiles.isEmpty) {
      stderr.writeln('Skip $folderName: no .ttf files');
      hadError = true;
      continue;
    }

    // 5. 区分预览字体（*-preview.ttf）与主字体文件
    File? previewFile;
    final fontCandidates = <File>[];

    for (final file in ttfFiles) {
      final baseName = _basename(file.path);
      if (baseName.toLowerCase().endsWith('-preview.ttf')) {
        previewFile = file;
      } else {
        fontCandidates.add(file);
      }
    }

    if (fontCandidates.isEmpty) {
      stderr.writeln('Skip $folderName: no main font .ttf (only preview?)');
      hadError = true;
      continue;
    }

    // 多个主字体时取体积最大的一个
    if (fontCandidates.length > 1) {
      fontCandidates.sort(
        (a, b) => b.lengthSync().compareTo(a.lengthSync()),
      );
      stderr.writeln(
        'Warning $folderName: multiple font files, using ${_basename(fontCandidates.first.path)}',
      );
    }

    final fontFile = fontCandidates.first;

    if (previewFile == null) {
      stderr.writeln('Warning $folderName: no *-preview.ttf found');
    }

    // 6. 组装索引条目（preview/font 为相对 fonts-repo 根目录的路径）
    entries.add({
      'id': id,
      'name': name,
      'family': id,
      'author': author,
      if (previewFile != null)
        'preview': _repoRelativePath(previewFile, repoRoot),
      'font': _repoRelativePath(fontFile, repoRoot),
      'size': fontFile.lengthSync(),
    });
  }

  // 7. 按 id 排序并写入 fonts-repo/index.json（不存在则创建，存在则全量更新）
  entries.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));

  final indexExists = indexFile.existsSync();
  final content = '${const JsonEncoder.withIndent('  ').convert(entries)}\n';

  if (indexExists) {
    indexFile.writeAsStringSync(content);
    stdout.writeln(
      'Updated ${entries.length} font(s) in ${indexFile.path}',
    );
  } else {
    indexFile.createSync(recursive: true);
    indexFile.writeAsStringSync(content);
    stdout.writeln(
      'Created ${indexFile.path} with ${entries.length} font(s)',
    );
  }
  if (hadError) exit(1);
}

/// 从 meta.json 读取非空字符串字段，缺失或为空时返回 null。
String? _optionalString(Map<String, dynamic> meta, String key) {
  final value = meta[key];
  if (value is! String || value.trim().isEmpty) return null;
  return value.trim();
}

/// 取路径最后一段文件名（兼容 Windows / Unix 分隔符）。
String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments = normalized.split('/').where((s) => s.isNotEmpty);
  return segments.isEmpty ? path : segments.last;
}

/// 返回 [file] 相对于 [repoRoot] 的路径，统一使用 `/` 分隔符。
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
