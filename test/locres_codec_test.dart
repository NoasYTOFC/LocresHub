import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:locres_hub/locres_codec.dart';

const _magic = <int>[
  0x0e,
  0x14,
  0x74,
  0x75,
  0x67,
  0x4a,
  0x03,
  0xfc,
  0x4a,
  0x15,
  0x90,
  0x9d,
  0xc3,
  0x37,
  0x7f,
  0x1b,
];

void main() {
  group('LocresCodec', () {
    test('reads and writes a legacy file without changing its hash', () {
      final file = _legacyFixture();
      final document = LocresCodec.parse(file);

      expect(document.version, 0);
      expect(document.entries.single.fullKey, 'UI::Greeting');
      expect(document.entries.single.originalText, 'Hello');
      expect(LocresCodec.serialize(document), file);

      document.entries.single.editedText = 'Olá, mundo';
      final saved = LocresCodec.serialize(document);
      final reopened = LocresCodec.parse(saved);

      expect(reopened.entries.single.editedText, 'Olá, mundo');
      expect(reopened.entries.single.sourceStringHash, 0x12345678);
      expect(saved.last, 0xab);
    });

    test('updates a compact string pool and its entry index', () {
      final document = LocresCodec.parse(_pooledFixture(1));

      expect(document.versionLabel, 'Compact');
      expect(document.entries.single.originalText, 'Hello');
      document.entries.single.editedText = 'Olá';

      final reopened = LocresCodec.parse(LocresCodec.serialize(document));
      expect(reopened.entries.single.editedText, 'Olá');
      expect(reopened.entries.single.sourceStringHash, 0x12345678);
    });

    test('preserves optimized version metadata when editing text', () {
      for (final version in [2, 3]) {
        final document = LocresCodec.parse(_pooledFixture(version));
        expect(document.version, version);
        document.entries.single.editedText = 'Texto novo';

        final reopened = LocresCodec.parse(LocresCodec.serialize(document));
        expect(reopened.entries.single.editedText, 'Texto novo');
        expect(reopened.entries.single.sourceStringHash, 0x12345678);
      }
    });

    test('rejects unsupported and truncated files', () {
      final unsupported = Uint8List.fromList([..._magic, 4, 0, 0, 0, 0]);
      expect(() => LocresCodec.parse(unsupported), throwsFormatException);
      expect(
        () => LocresCodec.parse(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
    });
  });
}

Uint8List _legacyFixture() {
  final writer = BytesBuilder()
    ..add(_i32(1))
    ..add(_fstring('UI'))
    ..add(_i32(1))
    ..add(_fstring('Greeting'))
    ..add(_u32(0x12345678))
    ..add(_fstring('Hello'))
    ..addByte(0xab);
  return writer.takeBytes();
}

Uint8List _pooledFixture(int version) {
  final writer = BytesBuilder()
    ..add(_magic)
    ..addByte(version)
    ..add(_i64(0));
  final offsetField = _magic.length + 1;

  if (version >= 2) writer.add(_i32(1));
  writer.add(_i32(1));
  if (version >= 2) writer.add(_u32(0x11111111));
  writer
    ..add(_fstring('UI'))
    ..add(_i32(1));
  if (version >= 2) writer.add(_u32(0x22222222));
  writer
    ..add(_fstring('Greeting'))
    ..add(_u32(0x12345678))
    ..add(_i32(0));

  final table = writer.takeBytes();
  final poolOffset = table.length;
  final poolWriter = BytesBuilder()
    ..add(table)
    ..add(_i32(1))
    ..add(_fstring('Hello'));
  if (version >= 2) poolWriter.add(_i32(1));
  final data = poolWriter.takeBytes();
  ByteData.sublistView(
    data,
    offsetField,
    offsetField + 8,
  ).setInt64(0, poolOffset, Endian.little);
  return data;
}

Uint8List _fstring(String value) {
  if (value.isEmpty) return _i32(0);
  if (value.runes.any((rune) => rune > 0x7f)) {
    final units = value.codeUnits;
    final writer = BytesBuilder()..add(_i32(-(units.length + 1)));
    for (final unit in units) {
      writer.add(<int>[unit & 0xff, unit >> 8]);
    }
    writer.add(const [0, 0]);
    return writer.takeBytes();
  }
  final bytes = ascii.encode(value);
  final writer = BytesBuilder()
    ..add(_i32(bytes.length + 1))
    ..add(bytes)
    ..addByte(0);
  return writer.takeBytes();
}

Uint8List _i32(int value) {
  final bytes = Uint8List(4);
  ByteData.sublistView(bytes).setInt32(0, value, Endian.little);
  return bytes;
}

Uint8List _u32(int value) {
  final bytes = Uint8List(4);
  ByteData.sublistView(bytes).setUint32(0, value, Endian.little);
  return bytes;
}

Uint8List _i64(int value) {
  final bytes = Uint8List(8);
  ByteData.sublistView(bytes).setInt64(0, value, Endian.little);
  return bytes;
}
