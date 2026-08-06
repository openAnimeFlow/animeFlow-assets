// 将插件 JSON 上传到 AnimeFlow Workers API。
//
// 使用：
//   dart plugins/script/upload_source_sites.dart plugins/gugu.json
//   dart plugins/script/upload_source_sites.dart plugins/gugu.json plugins/xfdm.json
//   dart plugins/script/upload_source_sites.dart --delete-base-url https://example.com/
//
// 必需环境变量：
//   SOURCE_SITE_API_URL   例如：https://source-site.example.com/
//   ANIME_FLOW_APP_ID
//   ANIME_FLOW_SECRET

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'plugin_schema.dart';

const _mask32 = 0xffffffff;

const _sha256Constants = <int>[
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
];

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      '用法：dart plugins/script/upload_source_sites.dart <plugin.json> [...]\n'
      '或：dart plugins/script/upload_source_sites.dart --delete-base-url <baseUrl>',
    );
    exitCode = 64;
    return;
  }

  final apiUrl = _requiredEnvironment('SOURCE_SITE_API_URL');
  final appId = _requiredEnvironment('ANIME_FLOW_APP_ID');
  final secret = _requiredEnvironment('ANIME_FLOW_SECRET');
  final endpoint = Uri.parse(apiUrl);

  if (!endpoint.hasScheme || !endpoint.hasAuthority) {
    stderr.writeln('SOURCE_SITE_API_URL 必须是完整的 HTTP(S) 地址');
    exitCode = 64;
    return;
  }

  if (args.first == '--delete-base-url') {
    if (args.length != 2 || args[1].trim().isEmpty) {
      stderr.writeln('--delete-base-url 必须且只能接收一个非空 baseUrl');
      exitCode = 64;
      return;
    }

    try {
      await _deleteSourceSite(
        endpoint: endpoint,
        appId: appId,
        secret: secret,
        baseUrl: args[1].trim(),
      );
      stdout.writeln('删除成功：${args[1].trim()}');
    } on HttpException catch (error) {
      stderr.writeln('删除失败：${args[1].trim()}');
      stderr.writeln(error.message);
      exitCode = 1;
    }
    return;
  }

  var failed = false;
  for (final inputPath in args) {
    final file = File(inputPath);
    if (!file.existsSync()) {
      stderr.writeln('文件不存在：$inputPath');
      failed = true;
      continue;
    }

    Map<String, dynamic> plugin;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('JSON 根节点必须是对象');
      }
      plugin = decoded;
    } on FormatException catch (error) {
      stderr.writeln('$inputPath 不是有效的 JSON：${error.message}');
      failed = true;
      continue;
    }

    final validation = validatePluginJson(plugin, inputPath);
    for (final warning in validation.warnings) {
      stdout.writeln('警告：$warning');
    }
    if (validation.failed) {
      for (final error in validation.errors) {
        stderr.writeln('校验失败：$error');
      }
      failed = true;
      continue;
    }

    try {
      final responseBody = await _uploadPlugin(
        endpoint: endpoint,
        appId: appId,
        secret: secret,
        plugin: plugin,
      );
      stdout.writeln('上传成功：$inputPath');
      stdout.writeln(responseBody);
    } on HttpException catch (error) {
      stderr.writeln('上传失败：$inputPath');
      stderr.writeln(error.message);
      failed = true;
    }
  }

  if (failed) {
    exitCode = 1;
  }
}

String _requiredEnvironment(String name) {
  final value = Platform.environment[name]?.trim();
  if (value == null || value.isEmpty) {
    stderr.writeln('缺少环境变量：$name');
    exit(64);
  }
  return value;
}

Future<String> _uploadPlugin({
  required Uri endpoint,
  required String appId,
  required String secret,
  required Map<String, dynamic> plugin,
}) async {
  final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final path = endpoint.path.isEmpty ? '/' : endpoint.path;
  final signature = base64Encode(
    _sha256(utf8.encode('$appId$timestamp$path$secret')),
  );
  final requestBody = jsonEncode(plugin);
  final client = HttpClient();

  try {
    final request = await client.postUrl(endpoint);
    request.headers.contentType = ContentType.json;
    request.headers.set('X-Auth', '1');
    request.headers.set('X-AppId', appId);
    request.headers.set('X-Timestamp', timestamp.toString());
    request.headers.set('X-Signature', signature);
    request.add(utf8.encode(requestBody));

    final response = await request.close();
    final responseBody = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.created &&
        response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'HTTP ${response.statusCode}: $responseBody',
        uri: endpoint,
      );
    }

    return responseBody;
  } finally {
    client.close(force: true);
  }
}

Future<void> _deleteSourceSite({
  required Uri endpoint,
  required String appId,
  required String secret,
  required String baseUrl,
}) async {
  final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final path = endpoint.path.isEmpty ? '/' : endpoint.path;
  final signature = base64Encode(
    _sha256(utf8.encode('$appId$timestamp$path$secret')),
  );
  final client = HttpClient();

  try {
    final request = await client.openUrl('DELETE', endpoint);
    request.headers.contentType = ContentType.json;
    request.headers.set('X-Auth', '1');
    request.headers.set('X-AppId', appId);
    request.headers.set('X-Timestamp', timestamp.toString());
    request.headers.set('X-Signature', signature);
    request.add(utf8.encode(jsonEncode({'baseUrl': baseUrl})));

    final response = await request.close();
    final responseBody = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.noContent) {
      throw HttpException(
        'HTTP ${response.statusCode}: $responseBody',
        uri: endpoint,
      );
    }
  } finally {
    client.close(force: true);
  }
}

Uint8List _sha256(List<int> input) {
  final bytes = <int>[...input];
  final bitLength = bytes.length * 8;
  bytes.add(0x80);
  while (bytes.length % 64 != 56) {
    bytes.add(0);
  }
  for (var shift = 56; shift >= 0; shift -= 8) {
    bytes.add((bitLength >> shift) & 0xff);
  }

  var h0 = 0x6a09e667;
  var h1 = 0xbb67ae85;
  var h2 = 0x3c6ef372;
  var h3 = 0xa54ff53a;
  var h4 = 0x510e527f;
  var h5 = 0x9b05688c;
  var h6 = 0x1f83d9ab;
  var h7 = 0x5be0cd19;

  for (var offset = 0; offset < bytes.length; offset += 64) {
    final words = List<int>.filled(64, 0);
    for (var index = 0; index < 16; index++) {
      final start = offset + index * 4;
      words[index] =
          (bytes[start] << 24) |
          (bytes[start + 1] << 16) |
          (bytes[start + 2] << 8) |
          bytes[start + 3];
    }
    for (var index = 16; index < 64; index++) {
      final smallSigma0 =
          _rotateRight(words[index - 15], 7) ^
          _rotateRight(words[index - 15], 18) ^
          (words[index - 15] >>> 3);
      final smallSigma1 =
          _rotateRight(words[index - 2], 17) ^
          _rotateRight(words[index - 2], 19) ^
          (words[index - 2] >>> 10);
      words[index] =
          (words[index - 16] + smallSigma0 + words[index - 7] + smallSigma1) &
          _mask32;
    }

    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;
    var f = h5;
    var g = h6;
    var h = h7;

    for (var index = 0; index < 64; index++) {
      final bigSigma1 =
          _rotateRight(e, 6) ^ _rotateRight(e, 11) ^ _rotateRight(e, 25);
      final choose = (e & f) ^ ((~e) & g);
      final temporary1 =
          (h + bigSigma1 + choose + _sha256Constants[index] + words[index]) &
          _mask32;
      final bigSigma0 =
          _rotateRight(a, 2) ^ _rotateRight(a, 13) ^ _rotateRight(a, 22);
      final majority = (a & b) ^ (a & c) ^ (b & c);
      final temporary2 = (bigSigma0 + majority) & _mask32;

      h = g;
      g = f;
      f = e;
      e = (d + temporary1) & _mask32;
      d = c;
      c = b;
      b = a;
      a = (temporary1 + temporary2) & _mask32;
    }

    h0 = (h0 + a) & _mask32;
    h1 = (h1 + b) & _mask32;
    h2 = (h2 + c) & _mask32;
    h3 = (h3 + d) & _mask32;
    h4 = (h4 + e) & _mask32;
    h5 = (h5 + f) & _mask32;
    h6 = (h6 + g) & _mask32;
    h7 = (h7 + h) & _mask32;
  }

  final digest = BytesBuilder(copy: false);
  for (final value in [h0, h1, h2, h3, h4, h5, h6, h7]) {
    digest.add([
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ]);
  }
  return digest.toBytes();
}

int _rotateRight(int value, int count) {
  return ((value >>> count) | (value << (32 - count))) & _mask32;
}
