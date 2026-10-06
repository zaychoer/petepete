import 'dart:convert';
import 'dart:io';

/// Thrown when an override does not fit the recorded sample.
class SampleOverrideError extends Error {
  SampleOverrideError(this.message);

  final String message;

  @override
  String toString() => 'SampleOverrideError: $message';
}

/// A recorded API response from `contract/` (ADR-0004), with a builder that
/// refuses to change the shape the server really sends.
///
/// ```dart
/// final page = Sample.load('pay_page.unpaid')
///     .patch({'amount_due': 50000, 'attempt': {'status': 'pending'}})
///     .withItems('lines', [{'label': 'Konsumsi'}, {}]);
/// page.json; // Map<String, dynamic>, a fresh deep copy
/// page.encode(); // JSON string for a fake HTTP response
/// ```
///
/// Rules (same comparer as the server's `Petepete.Contract`): an override keeps
/// the sample's JSON type per value (int, double, String, bool, List, Map);
/// `null` on either side is free; objects keep their key set. Values, ids and
/// timestamps are free.
class Sample {
  Sample._(this.name, this._json);

  /// `pay_page.unpaid` for `samples/pay_page.unpaid.json`, or `errors/<code>`.
  final String name;
  final Object? _json;

  /// Loads `contract/samples/<name>.json`. [contractDir] defaults to the
  /// repository's `contract/` directory.
  factory Sample.load(String name, {Directory? contractDir}) {
    final dir = contractDir ?? Sample.contractRoot();
    final file = File('${dir.path}/samples/$name.json');
    if (!file.existsSync()) {
      throw StateError('No contract sample $name (looked for ${file.path})');
    }
    return Sample._(name, jsonDecode(file.readAsStringSync()));
  }

  /// Loads the recorded error sample `contract/samples/errors/<code>.json`.
  factory Sample.error(String code, {Directory? contractDir}) =>
      Sample.load('errors/$code', contractDir: contractDir);

  /// The repository's `contract/` directory, found by walking up from the
  /// working directory (`flutter test` runs in `app/`) and the running script.
  static Directory contractRoot() {
    final starts = <Directory>[Directory.current];
    try {
      final script = Platform.script;
      if (script.scheme == 'file') {
        starts.add(File.fromUri(script).parent);
      }
    } on Object {
      // No usable script URI; the working directory is enough.
    }
    for (final start in starts) {
      var dir = start.absolute;
      while (true) {
        final candidate = Directory('${dir.path}/contract');
        if (File('${candidate.path}/manifest.json').existsSync()) {
          return candidate;
        }
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }
    throw StateError(
      'contract/manifest.json not found above ${Directory.current.path}',
    );
  }

  /// Reads and decodes a file in `contract/` such as `rupiah.json` or
  /// `manifest.json`.
  static Object? readContractFile(
    String relativePath, {
    Directory? contractDir,
  }) {
    final dir = contractDir ?? contractRoot();
    return jsonDecode(File('${dir.path}/$relativePath').readAsStringSync());
  }

  /// A fresh deep copy of the body, safe to mutate.
  Object? get body => _clone(_json);

  /// The body as an object. Throws if the sample is not a JSON object.
  Map<String, dynamic> get json => _clone(_json) as Map<String, dynamic>;

  /// The body as a JSON string, as the server would send it.
  String encode() => jsonEncode(_json);

  /// Returns a copy with [overrides] applied.
  ///
  /// A key is a field name or a dotted path (`'attempt.status'`,
  /// `'lines.0.amount'`; numeric segments index lists). A map value merges
  /// into the sample's object (unknown keys throw), a list value replaces the
  /// list with every element matching the sample's first element, anything
  /// else replaces the scalar. Throws [SampleOverrideError] when a path does
  /// not exist or a value changes the sample's JSON type.
  Sample patch(Map<String, dynamic> overrides) {
    final copy = _clone(_json);
    if (copy is! Map<String, dynamic>) {
      throw SampleOverrideError('$name is not a JSON object');
    }
    _mergeMap(copy, overrides, '');
    return Sample._(name, copy);
  }

  /// Returns a copy whose list at [path] holds one element per entry of
  /// [items]. Each element starts as the sample's first element and has the
  /// entry's overrides applied (same rules as [patch]); an empty map keeps
  /// the first element as recorded and an empty [items] gives an empty list.
  Sample withItems(String path, List<Map<String, dynamic>> items) {
    final copy = _clone(_json);
    final parent = _resolveParent(copy, path);
    final current = parent.read();
    if (current is! List) {
      throw SampleOverrideError(
        '${_label(path)} is ${_typeName(current)}, withItems needs a list',
      );
    }
    if (current.isEmpty) {
      throw SampleOverrideError(
        '${_label(path)} is empty in $name, record the sample with a '
        'non-empty list',
      );
    }
    final template = current.first;
    final built = <Object?>[];
    for (var i = 0; i < items.length; i++) {
      final element = _clone(template);
      if (items[i].isNotEmpty) {
        if (element is! Map<String, dynamic>) {
          throw SampleOverrideError(
            '$path.$i overrides need object elements, ${_label(path)} holds '
            '${_typeName(template)}',
          );
        }
        _mergeMap(element, items[i], '$path.$i');
      }
      built.add(element);
    }
    parent.write(built);
    return Sample._(name, copy);
  }

  @override
  String toString() => 'Sample($name)';
}

void _mergeMap(
  Map<String, dynamic> target,
  Map<String, dynamic> overrides,
  String prefix,
) {
  overrides.forEach((key, value) {
    final path = prefix.isEmpty ? key : '$prefix.$key';
    final parent = _resolveParent(target, key, prefix: prefix);
    _assign(parent, value, path);
  });
}

void _assign(_Slot slot, Object? value, String path) {
  final current = slot.read();
  if (value is Map<String, dynamic> && current is Map<String, dynamic>) {
    for (final key in value.keys) {
      if (!current.containsKey(key)) {
        throw SampleOverrideError(
          '$path.$key does not exist in the sample (keys: '
          '${(current.keys.toList()..sort()).join(', ')})',
        );
      }
    }
    for (final entry in value.entries) {
      _assign(_MapSlot(current, entry.key), entry.value, '$path.${entry.key}');
    }
    return;
  }
  _checkShape(current, value, path);
  slot.write(_clone(value));
}

/// Mirrors the server comparer: type per value, key set per object, list
/// elements against the sample's first element, `null` on either side free.
void _checkShape(Object? sample, Object? value, String path) {
  if (sample == null || value == null) return;
  if (_typeName(sample) != _typeName(value)) {
    throw SampleOverrideError(
      '$path changes type from ${_typeName(sample)} to ${_typeName(value)}',
    );
  }
  if (sample is Map && value is Map) {
    final missing = sample.keys.where((k) => !value.containsKey(k)).toList()
      ..sort();
    final extra = value.keys.where((k) => !sample.containsKey(k)).toList()
      ..sort();
    if (missing.isNotEmpty || extra.isNotEmpty) {
      throw SampleOverrideError(
        '$path changes the key set (missing: ${missing.join(', ')}; '
        'unexpected: ${extra.join(', ')})',
      );
    }
    for (final key in sample.keys) {
      _checkShape(sample[key], value[key], '$path.$key');
    }
  } else if (sample is List && value is List && sample.isNotEmpty) {
    for (var i = 0; i < value.length; i++) {
      _checkShape(sample.first, value[i], '$path.$i');
    }
  }
}

String _typeName(Object? v) => switch (v) {
  null => 'null',
  bool() => 'bool',
  int() => 'int',
  double() => 'double',
  String() => 'string',
  List() => 'list',
  Map() => 'map',
  _ => v.runtimeType.toString(),
};

String _label(String path) => path.isEmpty ? 'the body' : path;

Object? _clone(Object? v) => switch (v) {
  Map() => <String, dynamic>{
    for (final e in v.entries) e.key as String: _clone(e.value),
  },
  List() => <dynamic>[for (final e in v) _clone(e)],
  _ => v,
};

abstract class _Slot {
  Object? read();
  void write(Object? value);
}

class _MapSlot implements _Slot {
  _MapSlot(this.map, this.key);
  final Map<String, dynamic> map;
  final String key;
  @override
  Object? read() => map[key];
  @override
  void write(Object? value) => map[key] = value;
}

class _ListSlot implements _Slot {
  _ListSlot(this.list, this.index);
  final List<dynamic> list;
  final int index;
  @override
  Object? read() => list[index];
  @override
  void write(Object? value) => list[index] = value;
}

/// Walks a dotted [path] below [root] and returns the slot of its last
/// segment. [prefix] is only used for messages.
_Slot _resolveParent(Object? root, String path, {String prefix = ''}) {
  final segments = path.split('.');
  Object? node = root;
  var walked = prefix;
  for (var i = 0; i < segments.length; i++) {
    final seg = segments[i];
    final here = walked.isEmpty ? seg : '$walked.$seg';
    final last = i == segments.length - 1;
    _Slot slot;
    if (node is Map<String, dynamic>) {
      if (!node.containsKey(seg)) {
        throw SampleOverrideError(
          '$here does not exist in the sample (keys: '
          '${(node.keys.toList()..sort()).join(', ')})',
        );
      }
      slot = _MapSlot(node, seg);
    } else if (node is List) {
      final index = int.tryParse(seg);
      if (index == null || index < 0 || index >= node.length) {
        throw SampleOverrideError(
          '$here is not a valid index (list has ${node.length} elements)',
        );
      }
      slot = _ListSlot(node, index);
    } else {
      throw SampleOverrideError(
        '$walked is ${_typeName(node)} in the sample, override it as a whole '
        'instead of reaching into it',
      );
    }
    if (last) return slot;
    node = slot.read();
    walked = here;
  }
  throw SampleOverrideError('empty path');
}
