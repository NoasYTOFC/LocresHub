import 'dart:convert';
import 'dart:typed_data';

class LocresEntry {
  LocresEntry({
    required this.namespace,
    required this.key,
    required this.originalText,
    required this.sourceStringHash,
    required this.wasUtf16,
    required this.textOffset,
    this.originalPoolIndex,
    this.poolIndexOffset,
  }) : editedText = originalText;

  final String namespace;
  final String key;
  final String originalText;
  final int sourceStringHash;
  final bool wasUtf16;
  final int textOffset;
  final int? originalPoolIndex;
  final int? poolIndexOffset;
  String editedText;

  String get fullKey => namespace.isEmpty ? key : '$namespace::$key';
}

class LocresDocument {
  LocresDocument({
    required this.originalBytes,
    required this.version,
    required this.entries,
    required this.poolOffset,
    required this.poolEnd,
    required this.pool,
  });

  final Uint8List originalBytes;
  final int version;
  final List<LocresEntry> entries;
  final int? poolOffset;
  final int? poolEnd;
  final List<LocresPoolString> pool;

  String get versionLabel => switch (version) {
    0 => 'Legacy',
    1 => 'Compact',
    2 => 'Optimized',
    3 => 'CityHash64 UTF-16',
    _ => 'Desconhecida ($version)',
  };

  bool get isDirty =>
      entries.any((entry) => entry.editedText != entry.originalText);
}

class LocresPoolString {
  LocresPoolString(this.text, this.wasUtf16);

  final String text;
  final bool wasUtf16;
  int references = 0;
}

class _FString {
  _FString(this.value, this.wasUtf16, this.start, this.end);

  final String value;
  final bool wasUtf16;
  final int start;
  final int end;
}

class _EntryIndex {
  _EntryIndex({
    required this.namespace,
    required this.key,
    required this.hash,
    required this.index,
    required this.indexOffset,
  });

  final String namespace;
  final String key;
  final int hash;
  final int index;
  final int indexOffset;
}

class _LocresReader {
  _LocresReader(this.data, [this.position = 0]);

  final Uint8List data;
  int position;

  void _require(int count) {
    if (count < 0 || position > data.length - count) {
      throw const FormatException(
        'O arquivo Locres terminou antes do esperado.',
      );
    }
  }

  int readInt32() {
    _require(4);
    final value = ByteData.sublistView(
      data,
      position,
      position + 4,
    ).getInt32(0, Endian.little);
    position += 4;
    return value;
  }

  int readUint32() {
    _require(4);
    final value = ByteData.sublistView(
      data,
      position,
      position + 4,
    ).getUint32(0, Endian.little);
    position += 4;
    return value;
  }

  int readInt64() {
    _require(8);
    final value = ByteData.sublistView(
      data,
      position,
      position + 8,
    ).getInt64(0, Endian.little);
    position += 8;
    return value;
  }

  _FString readFString() {
    final start = position;
    final length = readInt32();
    if (length == 0) return _FString('', false, start, position);
    if (length == -0x80000000) {
      throw const FormatException('Comprimento inválido em uma string Locres.');
    }

    final utf16 = length < 0;
    final count = length.abs();
    final byteCount = utf16 ? count * 2 : count;
    _require(byteCount);
    var bytes = data.sublist(position, position + byteCount);
    position += byteCount;

    if (utf16) {
      var units = List<int>.generate(
        count,
        (index) => ByteData.sublistView(
          bytes,
          index * 2,
          index * 2 + 2,
        ).getUint16(0, Endian.little),
      );
      if (units.isNotEmpty && units.last == 0) {
        units = units.sublist(0, units.length - 1);
      }
      return _FString(String.fromCharCodes(units), true, start, position);
    }

    if (bytes.isNotEmpty && bytes.last == 0) {
      bytes = bytes.sublist(0, bytes.length - 1);
    }
    try {
      return _FString(utf8.decode(bytes), false, start, position);
    } on FormatException {
      throw const FormatException('Uma string do arquivo não é UTF-8 válido.');
    }
  }

  int readCount(String description) {
    final count = readInt32();
    if (count < 0 || count > data.length ~/ 4) {
      throw FormatException(
        'Quantidade inválida de $description no arquivo Locres.',
      );
    }
    return count;
  }
}

class LocresCodec {
  static const List<int> _magic = <int>[
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

  static LocresDocument parse(Uint8List bytes) {
    if (bytes.length < 4) {
      throw const FormatException(
        'O arquivo é pequeno demais para ser Locres.',
      );
    }

    final reader = _LocresReader(bytes);
    final magicMatches =
        bytes.length >= _magic.length &&
        List<int>.generate(
          _magic.length,
          (index) => bytes[index],
        ).asMap().entries.every((entry) => entry.value == _magic[entry.key]);
    var version = 0;
    final hasLocresHeader = magicMatches;
    if (hasLocresHeader) {
      reader.position = _magic.length;
      if (reader.position >= bytes.length) {
        throw const FormatException('O cabeçalho Locres está incompleto.');
      }
      version = bytes[reader.position++];
      if (version > 3) {
        throw FormatException(
          'A versão Locres $version ainda não é compatível.',
        );
      }
    }

    int? poolOffset;
    int? poolEnd;
    var expectedEntries = -1;
    if (version >= 1) {
      poolOffset = reader.readInt64();
      if (poolOffset < -1 || poolOffset > bytes.length) {
        throw const FormatException(
          'O deslocamento da tabela de textos é inválido.',
        );
      }
    }
    if (version >= 2) expectedEntries = reader.readCount('entradas');

    final namespaceCount = reader.readCount('namespaces');
    final entries = <LocresEntry>[];
    final poolReferences = <_EntryIndex>[];

    for (
      var namespaceIndex = 0;
      namespaceIndex < namespaceCount;
      namespaceIndex++
    ) {
      final namespace = _readKey(reader, version);
      final keyCount = reader.readCount('chaves');
      for (var keyIndex = 0; keyIndex < keyCount; keyIndex++) {
        final key = _readKey(reader, version);
        final sourceHash = reader.readUint32();
        if (version == 0) {
          final text = reader.readFString();
          entries.add(
            LocresEntry(
              namespace: namespace.value,
              key: key.value,
              originalText: text.value,
              sourceStringHash: sourceHash,
              wasUtf16: text.wasUtf16,
              textOffset: text.start,
            ),
          );
        } else {
          final indexOffset = reader.position;
          final index = reader.readInt32();
          poolReferences.add(
            _EntryIndex(
              namespace: namespace.value,
              key: key.value,
              hash: sourceHash,
              index: index,
              indexOffset: indexOffset,
            ),
          );
        }
      }
    }

    var pool = <LocresPoolString>[];
    if (version >= 1) {
      if (poolOffset == null) {
        throw const FormatException(
          'O deslocamento da tabela de textos está ausente.',
        );
      }
      if (poolOffset != -1 && poolOffset < reader.position) {
        throw const FormatException(
          'A tabela de textos se sobrepõe aos dados Locres.',
        );
      }
      if (poolOffset >= 0) {
        final poolReader = _LocresReader(bytes, poolOffset);
        final poolCount = poolReader.readCount('textos');
        pool = List<LocresPoolString>.generate(poolCount, (_) {
          final text = poolReader.readFString();
          final references = LocresPoolString(text.value, text.wasUtf16);
          if (version >= 2) references.references = poolReader.readInt32();
          return references;
        });
        poolEnd = poolReader.position;
      }

      for (final reference in poolReferences) {
        if (reference.index < -1 || reference.index >= pool.length) {
          throw const FormatException(
            'Uma entrada aponta para um texto inexistente.',
          );
        }
        final hasText = reference.index >= 0;
        final poolString = hasText ? pool[reference.index] : null;
        entries.add(
          LocresEntry(
            namespace: reference.namespace,
            key: reference.key,
            originalText: poolString?.text ?? '',
            sourceStringHash: reference.hash,
            wasUtf16: poolString?.wasUtf16 ?? false,
            textOffset: reference.indexOffset,
            originalPoolIndex: hasText ? reference.index : null,
            poolIndexOffset: reference.indexOffset,
          ),
        );
      }
    }

    if (version >= 2 && expectedEntries != entries.length) {
      throw const FormatException(
        'A quantidade de entradas do cabeçalho não confere.',
      );
    }

    return LocresDocument(
      originalBytes: bytes,
      version: version,
      entries: entries,
      poolOffset: poolOffset,
      poolEnd: poolEnd,
      pool: pool,
    );
  }

  static _FString _readKey(_LocresReader reader, int version) {
    if (version >= 2) reader.readUint32();
    return reader.readFString();
  }

  static Uint8List serialize(LocresDocument document) {
    if (!document.isDirty) return Uint8List.fromList(document.originalBytes);
    if (document.version == 0) return _serializeLegacy(document);

    final poolOffset = document.poolOffset;
    final poolEnd = document.poolEnd;
    if (poolOffset == null ||
        (poolOffset >= 0 && poolEnd == null) ||
        (poolOffset == -1 && document.version < 1)) {
      throw const FormatException(
        'Não é possível salvar uma tabela Locres sem pool válido.',
      );
    }

    final poolStart = poolOffset == -1
        ? document.originalBytes.length
        : poolOffset;
    final prefix = Uint8List.fromList(
      document.originalBytes.sublist(0, poolStart),
    );
    if (poolOffset == -1) {
      final offsetField = _magic.length + 1;
      if (offsetField + 8 > prefix.length) {
        throw const FormatException(
          'O cabeçalho Locres não contém o deslocamento do pool.',
        );
      }
      ByteData.sublistView(
        prefix,
        offsetField,
        offsetField + 8,
      ).setInt64(0, poolStart, Endian.little);
    }
    final pool = document.pool
        .map((entry) => LocresPoolString(entry.text, entry.wasUtf16))
        .toList();
    final knownStrings = <String, int>{};
    for (var index = 0; index < pool.length; index++) {
      knownStrings.putIfAbsent(pool[index].text, () => index);
    }

    for (final entry in document.entries) {
      final unchangedMissingText =
          entry.originalPoolIndex == null &&
          entry.editedText == entry.originalText;
      if (unchangedMissingText) continue;

      final index = knownStrings.putIfAbsent(entry.editedText, () {
        pool.add(LocresPoolString(entry.editedText, entry.wasUtf16));
        return pool.length - 1;
      });
      pool[index].references++;
      final indexOffset = entry.poolIndexOffset;
      if (indexOffset == null || indexOffset + 4 > prefix.length) {
        throw const FormatException('A posição de um texto Locres é inválida.');
      }
      ByteData.sublistView(
        prefix,
        indexOffset,
        indexOffset + 4,
      ).setInt32(0, index, Endian.little);
    }

    final writer = BytesBuilder(copy: false)
      ..add(prefix)
      ..add(_encodeInt32(pool.length));
    for (final value in pool) {
      writer.add(_encodeFString(value.text, value.wasUtf16));
      if (document.version >= 2) {
        writer.add(_encodeInt32(value.references));
      }
    }
    writer.add(document.originalBytes.sublist(poolEnd ?? poolStart));
    return writer.takeBytes();
  }

  static Uint8List _serializeLegacy(LocresDocument document) {
    final changed =
        document.entries
            .where((entry) => entry.editedText != entry.originalText)
            .toList()
          ..sort(
            (first, second) => first.textOffset.compareTo(second.textOffset),
          );
    final writer = BytesBuilder(copy: false);
    var cursor = 0;
    for (final entry in changed) {
      if (entry.textOffset < cursor) {
        throw const FormatException(
          'Os textos do arquivo Locres estão sobrepostos.',
        );
      }
      final field = _readLegacyFieldEnd(
        document.originalBytes,
        entry.textOffset,
      );
      writer
        ..add(document.originalBytes.sublist(cursor, entry.textOffset))
        ..add(_encodeFString(entry.editedText, entry.wasUtf16));
      cursor = field;
    }
    writer.add(document.originalBytes.sublist(cursor));
    return writer.takeBytes();
  }

  static int _readLegacyFieldEnd(Uint8List data, int start) {
    final reader = _LocresReader(data, start);
    return reader.readFString().end;
  }

  static Uint8List _encodeFString(String text, bool preserveUtf16) {
    if (text.isEmpty) return _encodeInt32(0);
    final useUtf16 = preserveUtf16 || text.runes.any((rune) => rune > 0x7f);
    if (useUtf16) {
      final units = text.codeUnits;
      final writer = BytesBuilder(copy: false)
        ..add(_encodeInt32(-(units.length + 1)));
      for (final unit in units) {
        writer.add(<int>[unit & 0xff, unit >> 8]);
      }
      writer.add(const <int>[0, 0]);
      return writer.takeBytes();
    }

    final bytes = ascii.encode(text);
    final writer = BytesBuilder(copy: false)
      ..add(_encodeInt32(bytes.length + 1))
      ..add(bytes)
      ..addByte(0);
    return writer.takeBytes();
  }

  static Uint8List _encodeInt32(int value) {
    final bytes = Uint8List(4);
    ByteData.sublistView(bytes).setInt32(0, value, Endian.little);
    return bytes;
  }
}
