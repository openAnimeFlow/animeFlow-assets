// 扫描 background-image/image 目录下的图片文件，生成 background-image/index.json 索引。
//
// 运行：dart background-image/script/update_index.dart

import 'dart:convert';
import 'dart:io';

const _rawBaseUrl =
    'https://raw.githubusercontent.com/openAnimeFlow/animeFlow-assets/main/background-image';

/// 支持的图片扩展名
const _imageExtensions = {'.jpg', '.jpeg', '.png', '.gif', '.webp'};

void main() {
  // 1. 定位 background-image/image 目录与输出 index.json
  final repoRoot = File(Platform.script.toFilePath()).parent.parent;
  final imageDir = Directory('${repoRoot.path}${Platform.pathSeparator}image');
  final indexFile = File('${repoRoot.path}${Platform.pathSeparator}index.json');

  if (!imageDir.existsSync()) {
    stderr.writeln('Image directory not found: ${imageDir.path}');
    exit(1);
  }

  // 2. 遍历 image 目录下的图片文件，收集图片信息
  final entries = <Map<String, dynamic>>[];

  for (final entity in imageDir.listSync()) {
    if (entity is! File) continue;

    final name = _basename(entity.path);

    // 只处理图片扩展名
    final ext = _extension(name).toLowerCase();
    if (!_imageExtensions.contains(ext)) continue;

    entries.add({
      'name': name,
      'url': _rawAssetUrl(entity, repoRoot),
      'size': entity.lengthSync(),
    });
  }

  // 3. 按文件名排序并写入 index.json
  entries.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));

  final content = '${const JsonEncoder.withIndent('  ').convert(entries)}\n';

  indexFile.createSync(recursive: true);
  indexFile.writeAsStringSync(content);

  stdout.writeln(
    'Updated ${entries.length} image(s) in ${indexFile.path}',
  );
}

/// 返回 [file] 对应的 raw GitHub 完整 URL。
String _rawAssetUrl(File file, Directory repoRoot) {
  final root = repoRoot.absolute.path;
  final full = file.absolute.path;
  final String relative;
  if (!full.startsWith(root)) {
    relative = full.replaceAll('\\', '/');
  } else {
    var path = full.substring(root.length);
    if (path.startsWith(Platform.pathSeparator)) {
      path = path.substring(Platform.pathSeparator.length);
    } else if (path.startsWith('/')) {
      path = path.substring(1);
    }
    relative = path.replaceAll('\\', '/');
  }
  return '$_rawBaseUrl/$relative';
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
