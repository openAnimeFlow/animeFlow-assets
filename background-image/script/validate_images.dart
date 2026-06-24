// 校验 background-image/image 目录下图片文件：
// - 单个文件不得超过 7MB
// - 文件名必须唯一
//
// 运行：dart background-image/script/validate_images.dart

import 'dart:io';

const _maxSize = 7 * 1024 * 1024; // 7 MB

/// 支持的图片扩展名
const _imageExtensions = {'.jpg', '.jpeg', '.png', '.gif', '.webp'};

void main() {
  final repoRoot = File(Platform.script.toFilePath()).parent.parent;
  final imageDir = Directory('${repoRoot.path}${Platform.pathSeparator}image');

  if (!imageDir.existsSync()) {
    stderr.writeln('Image directory not found: ${imageDir.path}');
    exit(1);
  }

  final imageFiles = imageDir
      .listSync()
      .whereType<File>()
      .where((f) => _imageExtensions.contains(_extension(f.path).toLowerCase()))
      .toList();

  if (imageFiles.isEmpty) {
    stdout.writeln('No image files found, skipping validation');
    return;
  }

  var anyFailed = false;
  final nameSet = <String>{};
  final duplicates = <String>[];

  for (final file in imageFiles) {
    final name = _basename(file.path);
    final size = file.lengthSync();

    // 1. 校验文件大小 < 7MB
    if (size >= _maxSize) {
      final mb = (size / (1024 * 1024)).toStringAsFixed(2);
      stderr.writeln('  Error: $name exceeds 7MB (${mb}MB)');
      anyFailed = true;
    }

    // 2. 校验文件名唯一性
    if (!nameSet.add(name)) {
      duplicates.add(name);
    }
  }

  if (duplicates.isNotEmpty) {
    for (final name in duplicates) {
      stderr.writeln('  Error: Duplicate filename "$name"');
    }
    anyFailed = true;
  }

  if (anyFailed) {
    stderr.writeln('');
    stderr.writeln('Validation FAILED');
    exit(1);
  }

  stdout.writeln('All ${imageFiles.length} image(s) passed validation');
}

/// 取路径最后一段文件名（兼容 Windows / Unix 分隔符）。
String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments = normalized.split('/').where((s) => s.isNotEmpty);
  return segments.isEmpty ? path : segments.last;
}

/// 取文件扩展名（含点号）。
String _extension(String filename) {
  final dot = filename.lastIndexOf('.');
  return dot == -1 ? '' : filename.substring(dot);
}
