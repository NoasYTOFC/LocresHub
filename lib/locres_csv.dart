import 'dart:convert';
import 'dart:typed_data';

import 'locres_codec.dart';

typedef LocresCsvEntryId = ({
  String namespace,
  String key,
  int sourceStringHash,
});

class LocresCsvSource {
  const LocresCsvSource({required this.name, required this.content});

  final String name;
  final String content;
}

class LocresCsvValue {
  const LocresCsvValue({
    required this.id,
    required this.original,
    required this.edited,
    required this.sourceName,
  });

  final LocresCsvEntryId id;
  final String original;
  final String edited;
  final String sourceName;
}

class LocresCsvConflict {
  const LocresCsvConflict({required this.id, required this.values});

  final LocresCsvEntryId id;
  final List<LocresCsvValue> values;
}

class LocresCsvMergePlan {
  const LocresCsvMergePlan({
    required this.changes,
    required this.conflicts,
    required this.unmatchedRows,
  });

  final Map<LocresCsvEntryId, LocresCsvValue> changes;
  final List<LocresCsvConflict> conflicts;
  final int unmatchedRows;
}

class LocresCsv {
  static const _headers = [
    'namespace',
    'key',
    'original',
    'edited',
    'sourceStringHash',
  ];

  static List<int> exportEntries(
    Iterable<LocresEntry> entries, {
    required bool editedOnly,
  }) {
    final output = StringBuffer('\uFEFF');
    _writeRecord(output, _headers);
    for (final entry in entries) {
      final edited = entry.editedText == entry.originalText
          ? ''
          : entry.editedText;
      if (editedOnly && edited.isEmpty) continue;
      _writeRecord(output, [
        entry.namespace,
        entry.key,
        entry.originalText,
        edited,
        entry.sourceStringHash.toString(),
      ]);
    }
    return utf8.encode(output.toString());
  }

  static LocresDocument parseDocument(String content) {
    final records = _parseRecords(content);
    if (records.isEmpty) {
      throw const FormatException('O CSV está vazio.');
    }
    final header = records.first;
    final columnIndexes = _columnIndexes(header, 'CSV');
    if (_headers.any((name) => !columnIndexes.containsKey(name))) {
      throw FormatException(
        'O CSV precisa conter as colunas: ${_headers.join(', ')}.',
      );
    }
    final entries = <LocresEntry>[];
    for (var recordIndex = 1; recordIndex < records.length; recordIndex++) {
      final record = records[recordIndex];
      if (record.every((field) => field.isEmpty)) continue;
      if (record.length != header.length) {
        throw FormatException(
          'A linha ${recordIndex + 1} do CSV tem ${record.length} colunas; eram esperadas ${header.length}.',
        );
      }
      String column(String name) => record[columnIndexes[name]!];
      final hash = int.tryParse(column('sourceStringHash'));
      if (hash == null) {
        throw FormatException(
          'O hash na linha ${recordIndex + 1} do CSV não é um número válido.',
        );
      }
      final original = column('original');
      final edited = column('edited');
      entries.add(
        LocresEntry(
          namespace: column('namespace'),
          key: column('key'),
          originalText: original,
          sourceStringHash: hash,
          wasUtf16: false,
          textOffset: entries.length,
        )..editedText = edited.isEmpty ? original : edited,
      );
    }
    return LocresDocument(
      originalBytes: Uint8List(0),
      version: 0,
      poolOffset: null,
      poolEnd: null,
      pool: [],
      entries: entries,
    );
  }

  static LocresCsvMergePlan prepareMerge(
    LocresDocument document,
    Iterable<LocresCsvSource> sources,
  ) {
    final entriesById = <LocresCsvEntryId, LocresEntry>{};
    for (final entry in document.entries) {
      final id = (
        namespace: entry.namespace,
        key: entry.key,
        sourceStringHash: entry.sourceStringHash,
      );
      if (entriesById.containsKey(id)) {
        throw FormatException(
          'O Locres contém mais de uma entrada com a mesma chave e hash: ${entry.fullKey}.',
        );
      }
      entriesById[id] = entry;
    }

    final valuesById = <LocresCsvEntryId, List<LocresCsvValue>>{};
    var unmatchedRows = 0;
    for (final source in sources) {
      final records = _parseRecords(source.content);
      if (records.isEmpty) {
        throw FormatException('O CSV "${source.name}" está vazio.');
      }
      final header = records.first;
      final columnIndexes = _columnIndexes(header, source.name);
      if (_headers.any((name) => !columnIndexes.containsKey(name))) {
        throw FormatException(
          'O CSV "${source.name}" precisa conter as colunas: ${_headers.join(', ')}.',
        );
      }

      for (var recordIndex = 1; recordIndex < records.length; recordIndex++) {
        final record = records[recordIndex];
        if (record.every((field) => field.isEmpty)) continue;
        if (record.length != header.length) {
          throw FormatException(
            'A linha ${recordIndex + 1} do CSV "${source.name}" tem ${record.length} colunas; eram esperadas ${header.length}.',
          );
        }
        String column(String name) => record[columnIndexes[name]!];
        final hash = int.tryParse(column('sourceStringHash'));
        if (hash == null) {
          throw FormatException(
            'O hash na linha ${recordIndex + 1} do CSV "${source.name}" não é um número válido.',
          );
        }
        final id = (
          namespace: column('namespace'),
          key: column('key'),
          sourceStringHash: hash,
        );
        final edited = column('edited');
        if (edited.isEmpty) continue;
        if (!entriesById.containsKey(id)) {
          unmatchedRows++;
          continue;
        }
        valuesById
            .putIfAbsent(id, () => [])
            .add(
              LocresCsvValue(
                id: id,
                original: column('original'),
                edited: edited,
                sourceName: source.name,
              ),
            );
      }
    }

    final changes = <LocresCsvEntryId, LocresCsvValue>{};
    final conflicts = <LocresCsvConflict>[];
    for (final entry in valuesById.entries) {
      final valuesByText = <String, LocresCsvValue>{};
      for (final value in entry.value) {
        valuesByText.putIfAbsent(value.edited, () => value);
      }
      final values = valuesByText.values.toList(growable: false);
      if (values.length == 1) {
        changes[entry.key] = values.single;
      } else {
        conflicts.add(LocresCsvConflict(id: entry.key, values: values));
      }
    }

    return LocresCsvMergePlan(
      changes: changes,
      conflicts: conflicts,
      unmatchedRows: unmatchedRows,
    );
  }

  static Map<LocresCsvEntryId, LocresCsvValue> resolveConflicts(
    LocresCsvMergePlan plan,
    Map<LocresCsvEntryId, String> selectedValues,
  ) {
    final changes = Map<LocresCsvEntryId, LocresCsvValue>.from(plan.changes);
    for (final conflict in plan.conflicts) {
      final selectedText = selectedValues[conflict.id];
      final selected = conflict.values
          .where((value) => value.edited == selectedText)
          .firstOrNull;
      if (selected == null) {
        throw const FormatException(
          'É necessário escolher um valor para cada conflito de CSV.',
        );
      }
      changes[conflict.id] = selected;
    }
    return changes;
  }

  static void _writeRecord(StringBuffer output, List<String> fields) {
    output
      ..write(fields.map(_escapeField).join(','))
      ..write('\r\n');
  }

  static String _escapeField(String value) =>
      '"${value.replaceAll('"', '""')}"';

  static Map<String, int> _columnIndexes(List<String> header, String name) {
    final indexes = <String, int>{};
    for (var index = 0; index < header.length; index++) {
      if (indexes.containsKey(header[index])) {
        throw FormatException(
          'O CSV "$name" tem uma coluna duplicada: ${header[index]}.',
        );
      }
      indexes[header[index]] = index;
    }
    return indexes;
  }

  static List<List<String>> _parseRecords(String input) {
    final content = input.startsWith('\uFEFF') ? input.substring(1) : input;
    final records = <List<String>>[];
    final record = <String>[];
    final field = StringBuffer();
    var inQuotes = false;
    var afterQuote = false;

    void finishField() {
      record.add(field.toString());
      field.clear();
      afterQuote = false;
    }

    void finishRecord() {
      finishField();
      records.add(List<String>.from(record));
      record.clear();
    }

    for (var index = 0; index < content.length; index++) {
      final character = content[index];
      if (inQuotes) {
        if (character == '"') {
          if (index + 1 < content.length && content[index + 1] == '"') {
            field.write('"');
            index++;
          } else {
            inQuotes = false;
            afterQuote = true;
          }
        } else {
          field.write(character);
        }
        continue;
      }

      if (character == ',') {
        finishField();
      } else if (character == '\n' || character == '\r') {
        finishRecord();
        if (character == '\r' &&
            index + 1 < content.length &&
            content[index + 1] == '\n') {
          index++;
        }
      } else if (character == '"') {
        if (field.isNotEmpty || afterQuote) {
          throw const FormatException(
            'O CSV contém aspas em uma posição inválida.',
          );
        }
        inQuotes = true;
      } else {
        if (afterQuote) {
          throw const FormatException(
            'O CSV contém texto após o fechamento de aspas.',
          );
        }
        field.write(character);
      }
    }

    if (inQuotes) {
      throw const FormatException('O CSV termina com uma aspa não fechada.');
    }
    if (field.isNotEmpty || record.isNotEmpty || afterQuote) {
      finishRecord();
    }
    return records;
  }
}
