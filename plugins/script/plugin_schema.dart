/// 插件 JSON 结构与校验规则

const requiredStringFields = [
  'version',
  'name',
  'iconUrl',
  'baseUrl',
  'searchUrl',
  'searchList',
  'searchName',
  'searchLink',
  'lineNames',
  'lineList',
  'episode',
];

final _semverPattern = RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+$');
final _httpUrlPattern = RegExp(r'^https?://');

class PluginValidation {
  PluginValidation({
    required this.errors,
    required this.warnings,
  });

  final List<String> errors;
  final List<String> warnings;

  bool get failed => errors.isNotEmpty;
}

PluginValidation validatePluginJson(
  Map<String, dynamic> json,
  String fileLabel,
) {
  final errors = <String>[];
  final warnings = <String>[];

  for (final field in requiredStringFields) {
    if (!json.containsKey(field)) {
      errors.add('$fileLabel: missing required field: $field');
      continue;
    }
    final value = json[field];
    if (value == null) {
      errors.add('$fileLabel: field "$field" has null value (required non-null)');
    } else if (value is! String) {
      errors.add(
        '$fileLabel: field "$field" type mismatch. Expected: string, Got: ${value.runtimeType}',
      );
    }
  }

  for (final key in json.keys) {
    if (!requiredStringFields.contains(key)) {
      warnings.add('$fileLabel: extra field "$key" found (not in template)');
    }
  }

  final version = json['version'];
  if (version is String && !_semverPattern.hasMatch(version)) {
    warnings.add(
      "$fileLabel: version format should be semantic (e.g. '1.0.0'), got: '$version'",
    );
  }

  void warnUrl(String field, {bool requireKeyword = false}) {
    final value = json[field];
    if (value is! String) return;
    if (!_httpUrlPattern.hasMatch(value)) {
      warnings.add(
        "$fileLabel: $field should be a valid HTTP(S) URL, got: '$value'",
      );
    } else if (requireKeyword && !value.contains('{keyword}')) {
      warnings.add(
        "$fileLabel: searchUrl should contain {keyword} placeholder, got: '$value'",
      );
    }
  }

  warnUrl('iconUrl');
  warnUrl('baseUrl');
  warnUrl('searchUrl', requireKeyword: true);

  return PluginValidation(errors: errors, warnings: warnings);
}
