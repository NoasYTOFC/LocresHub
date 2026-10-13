import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:locres_hub/locres_codec.dart';
import 'package:locres_hub/locres_csv.dart';

void main() {
  test('exports edited rows and creates mergeable namespace templates', () {
    final changed = _entry(
      namespace: 'UI',
      key: 'Play',
      original: 'Play, now',
      edited: 'Jogar,\n"agora"',
    );
    final untouched = _entry(
      namespace: 'UI',
      key: 'Quit',
      original: 'Quit',
      edited: 'Quit',
    );

    final editedCsv = utf8.decode(
      LocresCsv.exportEntries([changed, untouched], editedOnly: true),
    );
    expect(editedCsv, contains('"Jogar,\n""agora"""'));
    expect(editedCsv, contains('"Play, now"'));
    expect(editedCsv, isNot(contains('"Quit"')));

    final templateCsv = utf8.decode(
      LocresCsv.exportEntries([changed, untouched], editedOnly: false),
    );
    final document = _document([changed, untouched]);
    final plan = LocresCsv.prepareMerge(document, [
      LocresCsvSource(name: 'parte.csv', content: templateCsv),
    ]);
    expect(plan.changes, hasLength(1));
    expect(plan.changes.values.single.edited, 'Jogar,\n"agora"');
    expect(plan.conflicts, isEmpty);
  });

  test(
    'opens a CSV alone as a document while keeping blank edits unchanged',
    () {
      const csv =
          'namespace,key,original,edited,sourceStringHash\r\n'
          'UI,Play,Play,Iniciar,8\r\n'
          'UI,Quit,Quit,,9\r\n';

      final document = LocresCsv.parseDocument(csv);

      expect(document.entries, hasLength(2));
      expect(document.entries[0].editedText, 'Iniciar');
      expect(document.entries[1].editedText, 'Quit');
      document.entries[1].editedText = 'Sair';
      final exported = utf8.decode(
        LocresCsv.exportEntries(document.entries, editedOnly: false),
      );
      final reparsed = LocresCsv.parseDocument(exported);
      expect(reparsed.entries[0].editedText, 'Iniciar');
      expect(reparsed.entries[1].editedText, 'Sair');
    },
  );

  test(
    'merges by namespace, key and source hash, ignoring blank and stale rows',
    () {
      final document = _document([
        _entry(namespace: 'UI', key: 'Play', original: 'Play', hash: 8),
      ]);
      const csv =
          'namespace,key,original,edited,sourceStringHash\r\n'
          'UI,Play,Play,Iniciar,8\r\n'
          'UI,Missing,Text,Ignorar,8\r\n'
          'UI,Play,Play,,8\r\n';

      final plan = LocresCsv.prepareMerge(document, [
        const LocresCsvSource(name: 'translations.csv', content: csv),
      ]);

      expect(plan.changes.values.single.edited, 'Iniciar');
      expect(plan.unmatchedRows, 1);
    },
  );

  test('reports conflicting CSV values and requires a choice for each key', () {
    final document = _document([
      _entry(namespace: 'UI', key: 'Play', original: 'Play', hash: 8),
    ]);
    const header = 'namespace,key,original,edited,sourceStringHash\r\n';
    final plan = LocresCsv.prepareMerge(document, [
      const LocresCsvSource(
        name: 'a.csv',
        content: '${header}UI,Play,Play,Iniciar,8\r\n',
      ),
      const LocresCsvSource(
        name: 'b.csv',
        content: '${header}UI,Play,Play,Começar,8\r\n',
      ),
    ]);

    expect(plan.conflicts, hasLength(1));
    expect(
      () => LocresCsv.resolveConflicts(plan, const {}),
      throwsFormatException,
    );
    final id = plan.conflicts.single.id;
    final resolved = LocresCsv.resolveConflicts(plan, {id: 'Começar'});
    expect(resolved[id]?.edited, 'Começar');
  });

  test('rejects malformed CSV columns and hashes', () {
    final document = _document([]);
    expect(
      () => LocresCsv.prepareMerge(document, const [
        LocresCsvSource(name: 'wrong.csv', content: 'wrong,header\n'),
      ]),
      throwsFormatException,
    );
    expect(
      () => LocresCsv.prepareMerge(document, const [
        LocresCsvSource(
          name: 'wrong-hash.csv',
          content:
              'namespace,key,original,edited,sourceStringHash\n'
              'UI,Play,Play,Iniciar,not-a-number\n',
        ),
      ]),
      throwsFormatException,
    );
  });
}

LocresEntry _entry({
  required String namespace,
  required String key,
  required String original,
  String? edited,
  int hash = 7,
}) {
  return LocresEntry(
    namespace: namespace,
    key: key,
    originalText: original,
    sourceStringHash: hash,
    wasUtf16: false,
    textOffset: 0,
  )..editedText = edited ?? original;
}

LocresDocument _document(List<LocresEntry> entries) => LocresDocument(
  originalBytes: Uint8List(0),
  version: 0,
  poolOffset: null,
  poolEnd: null,
  pool: [],
  entries: entries,
);
