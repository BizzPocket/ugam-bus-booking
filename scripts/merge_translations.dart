// Merges every partial JSON under assets/translations/_partials/ into the
// top-level en.json / gu.json / hi.json. Run from the repo root with:
//
//   dart run scripts/merge_translations.dart
//
// Each partial has the shape:
//   { "en": {"screen": {...}}, "gu": {"screen": {...}}, "hi": {"screen": {...}} }
//
// The script deep-merges the en/gu/hi maps into the existing root files so
// foundation keys (app.action.*, app.error.*, settings.language.*, language.*)
// are preserved.

import 'dart:convert';
import 'dart:io';

const _locales = ['en', 'gu', 'hi'];
const _root = 'assets/translations';
const _partials = 'assets/translations/_partials';

void main() {
  final merged = <String, Map<String, dynamic>>{};
  for (final loc in _locales) {
    final f = File('$_root/$loc.json');
    merged[loc] = f.existsSync()
        ? (jsonDecode(f.readAsStringSync()) as Map<String, dynamic>)
        : <String, dynamic>{};
  }

  final partialFiles = Directory(_partials)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final f in partialFiles) {
    final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    for (final loc in _locales) {
      final section = data[loc];
      if (section is Map<String, dynamic>) {
        _deepMerge(merged[loc]!, section);
      }
    }
    stdout.writeln('merged ${f.uri.pathSegments.last}');
  }

  const encoder = JsonEncoder.withIndent('  ');
  for (final loc in _locales) {
    File('$_root/$loc.json').writeAsStringSync('${encoder.convert(merged[loc])}\n');
  }
  stdout.writeln('wrote ${_locales.map((l) => '$_root/$l.json').join(', ')}');
}

void _deepMerge(Map<String, dynamic> into, Map<String, dynamic> from) {
  from.forEach((k, v) {
    if (v is Map<String, dynamic> && into[k] is Map<String, dynamic>) {
      _deepMerge(into[k] as Map<String, dynamic>, v);
    } else {
      into[k] = v;
    }
  });
}
