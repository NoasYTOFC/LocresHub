import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:path_provider/path_provider.dart';

import 'locres_codec.dart';

enum WorkspaceSourceType { locres, csv }

class LocresWorkspaceTab {
  LocresWorkspaceTab({
    required this.path,
    required this.projectName,
    required this.document,
    required this.aliases,
    this.sourceType = WorkspaceSourceType.locres,
    this.selectedNamespace,
    this.lastSavedPath,
    Map<int, String>? savedEdits,
    Set<String>? finalizedNamespaces,
  }) : savedEdits = savedEdits ?? {},
       finalizedNamespaces = finalizedNamespaces ?? {};

  final String path;
  String projectName;
  final LocresDocument document;
  final Map<String, String> aliases;
  final WorkspaceSourceType sourceType;
  String? selectedNamespace;
  String? lastSavedPath;
  Map<int, String> savedEdits;
  final Set<String> finalizedNamespaces;

  String get fileName => path.split(Platform.pathSeparator).last;

  Map<int, String> get currentEdits {
    final edits = <int, String>{};
    for (var index = 0; index < document.entries.length; index++) {
      final entry = document.entries[index];
      if (entry.editedText != entry.originalText) {
        edits[index] = entry.editedText;
      }
    }
    return edits;
  }

  bool get hasUnsavedChanges {
    final current = currentEdits;
    if (current.length != savedEdits.length) return true;
    return current.entries.any((entry) => savedEdits[entry.key] != entry.value);
  }

  bool get hasEdits => document.isDirty;

  void markSaved() => savedEdits = currentEdits;
}

class SavedLocresEdit {
  const SavedLocresEdit({
    required this.index,
    required this.fullKey,
    required this.sourceStringHash,
    required this.text,
  });

  final int index;
  final String fullKey;
  final int sourceStringHash;
  final String text;
}

class WorkspaceTabRecord {
  const WorkspaceTabRecord({
    required this.path,
    required this.projectName,
    required this.aliases,
    required this.edits,
    required this.savedEdits,
    this.sourceType = WorkspaceSourceType.locres,
    this.finalizedNamespaces = const {},
    this.selectedNamespace,
    this.lastSavedPath,
  });

  final String path;
  final String projectName;
  final Map<String, String> aliases;
  final List<SavedLocresEdit> edits;
  final List<SavedLocresEdit> savedEdits;
  final WorkspaceSourceType sourceType;
  final Set<String> finalizedNamespaces;
  final String? selectedNamespace;
  final String? lastSavedPath;
}

class SavedLocresMetadata {
  const SavedLocresMetadata({
    required this.path,
    required this.projectName,
    required this.aliases,
    this.finalizedNamespaces = const {},
  });

  final String path;
  final String projectName;
  final Map<String, String> aliases;
  final Set<String> finalizedNamespaces;
}

class WorkspaceSnapshot {
  const WorkspaceSnapshot({
    required this.tabs,
    required this.knownFiles,
    this.themeMode = ThemeMode.system,
    this.activePath,
  });

  final List<WorkspaceTabRecord> tabs;
  final List<SavedLocresMetadata> knownFiles;
  final ThemeMode themeMode;
  final String? activePath;
}

class WorkspaceStore {
  const WorkspaceStore({this.directory});

  final Directory? directory;

  Future<WorkspaceSnapshot> load() async {
    final file = File(
      '${(await _getDirectory()).path}${Platform.pathSeparator}workspace.json',
    );
    if (!await file.exists()) {
      return const WorkspaceSnapshot(tabs: [], knownFiles: []);
    }

    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic> ||
        decoded['schemaVersion'] != 1 ||
        decoded['tabs'] is! List ||
        (decoded['knownFiles'] != null && decoded['knownFiles'] is! List)) {
      throw const FormatException(
        'O arquivo local do espaço de trabalho é inválido.',
      );
    }

    final tabs = (decoded['tabs'] as List)
        .map(_readTab)
        .toList(growable: false);
    if (tabs.length > 5) {
      throw const FormatException(
        'O espaço de trabalho contém mais de cinco Locres.',
      );
    }
    final activePath = decoded['activePath'];
    if (activePath != null && activePath is! String) {
      throw const FormatException(
        'O arquivo local do espaço de trabalho é inválido.',
      );
    }
    final knownFiles = decoded['knownFiles'] == null
        ? tabs
              .map(
                (tab) => SavedLocresMetadata(
                  path: tab.path,
                  projectName: tab.projectName,
                  aliases: tab.aliases,
                  finalizedNamespaces: tab.finalizedNamespaces,
                ),
              )
              .toList(growable: false)
        : (decoded['knownFiles'] as List)
              .map(_readMetadata)
              .toList(growable: false);
    return WorkspaceSnapshot(
      tabs: tabs,
      knownFiles: knownFiles,
      themeMode: _readThemeMode(decoded['themeMode']),
      activePath: activePath as String?,
    );
  }

  Future<void> save(
    List<LocresWorkspaceTab> tabs,
    LocresWorkspaceTab? activeTab, {
    List<SavedLocresMetadata> knownFiles = const [],
    ThemeMode themeMode = ThemeMode.system,
  }) async {
    if (tabs.length > 5) {
      throw const FormatException(
        'O espaço de trabalho não pode exceder cinco Locres.',
      );
    }
    final directory = await _getDirectory();
    await directory.create(recursive: true);
    final data = <String, Object?>{
      'schemaVersion': 1,
      'activePath': activeTab?.path,
      'themeMode': themeMode.name,
      'tabs': tabs.map(_writeTab).toList(),
      'knownFiles':
          (knownFiles.isEmpty
                  ? tabs
                        .map(
                          (tab) => SavedLocresMetadata(
                            path: tab.path,
                            projectName: tab.projectName,
                            aliases: tab.aliases,
                            finalizedNamespaces: tab.finalizedNamespaces,
                          ),
                        )
                        .toList()
                  : knownFiles)
              .map(_writeMetadata)
              .toList(),
    };
    final file = File(
      '${directory.path}${Platform.pathSeparator}workspace.json',
    );
    await file.writeAsString(jsonEncode(data), flush: true);
  }

  Future<Directory> _getDirectory() async =>
      directory ?? await getApplicationSupportDirectory();

  ThemeMode _readThemeMode(Object? value) {
    if (value == null) return ThemeMode.system;
    for (final mode in ThemeMode.values) {
      if (mode.name == value) return mode;
    }
    throw const FormatException(
      'O tema salvo no espaço de trabalho é inválido.',
    );
  }

  WorkspaceSourceType _readSourceType(Object? value) {
    if (value == null) return WorkspaceSourceType.locres;
    for (final type in WorkspaceSourceType.values) {
      if (type.name == value) return type;
    }
    throw const FormatException(
      'O tipo do arquivo salvo no espaço de trabalho é inválido.',
    );
  }

  WorkspaceTabRecord _readTab(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['path'] is! String ||
        value['projectName'] is! String ||
        (value['sourceType'] != null && value['sourceType'] is! String) ||
        value['aliases'] is! Map ||
        value['edits'] is! List ||
        (value['savedEdits'] != null && value['savedEdits'] is! List) ||
        (value['finalizedNamespaces'] != null &&
            value['finalizedNamespaces'] is! List)) {
      throw const FormatException(
        'Um Locres salvo no espaço de trabalho é inválido.',
      );
    }

    final aliases = <String, String>{};
    for (final entry in (value['aliases'] as Map).entries) {
      if (entry.key is! String || entry.value is! String) {
        throw const FormatException('Os apelidos salvos são inválidos.');
      }
      aliases[entry.key as String] = entry.value as String;
    }

    List<SavedLocresEdit> readEdits(Object? rawEdits) => (rawEdits as List)
        .map((edit) {
          if (edit is! Map<String, dynamic> ||
              edit['index'] is! int ||
              edit['fullKey'] is! String ||
              edit['sourceStringHash'] is! int ||
              edit['text'] is! String) {
            throw const FormatException(
              'Uma edição salva no espaço de trabalho é inválida.',
            );
          }
          return SavedLocresEdit(
            index: edit['index'] as int,
            fullKey: edit['fullKey'] as String,
            sourceStringHash: edit['sourceStringHash'] as int,
            text: edit['text'] as String,
          );
        })
        .toList(growable: false);
    final edits = readEdits(value['edits']);
    final savedEdits = readEdits(value['savedEdits'] ?? const []);

    final lastSavedPath = value['lastSavedPath'];
    if (lastSavedPath != null && lastSavedPath is! String) {
      throw const FormatException('O caminho Locres salvo é inválido.');
    }
    final selectedNamespace = value['selectedNamespace'];
    if (selectedNamespace != null && selectedNamespace is! String) {
      throw const FormatException('O conjunto selecionado é inválido.');
    }
    final finalizedNamespaces = _readFinalizedNamespaces(
      value['finalizedNamespaces'],
    );
    return WorkspaceTabRecord(
      path: value['path'] as String,
      projectName: value['projectName'] as String,
      aliases: aliases,
      edits: edits,
      savedEdits: savedEdits,
      sourceType: _readSourceType(value['sourceType']),
      finalizedNamespaces: finalizedNamespaces,
      selectedNamespace: selectedNamespace as String?,
      lastSavedPath: lastSavedPath as String?,
    );
  }

  SavedLocresMetadata _readMetadata(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['path'] is! String ||
        value['projectName'] is! String ||
        value['aliases'] is! Map ||
        (value['finalizedNamespaces'] != null &&
            value['finalizedNamespaces'] is! List)) {
      throw const FormatException(
        'Os dados locais de um projeto são inválidos.',
      );
    }
    final aliases = <String, String>{};
    for (final entry in (value['aliases'] as Map).entries) {
      if (entry.key is! String || entry.value is! String) {
        throw const FormatException('Os apelidos salvos são inválidos.');
      }
      aliases[entry.key as String] = entry.value as String;
    }
    return SavedLocresMetadata(
      path: value['path'] as String,
      projectName: value['projectName'] as String,
      aliases: aliases,
      finalizedNamespaces: _readFinalizedNamespaces(
        value['finalizedNamespaces'],
      ),
    );
  }

  Map<String, Object?> _writeMetadata(SavedLocresMetadata metadata) => {
    'path': metadata.path,
    'projectName': metadata.projectName,
    'aliases': metadata.aliases,
    'finalizedNamespaces': metadata.finalizedNamespaces.toList()..sort(),
  };

  Set<String> _readFinalizedNamespaces(Object? value) {
    if (value == null) return {};
    final namespaces = <String>{};
    for (final namespace in value as List) {
      if (namespace is! String) {
        throw const FormatException(
          'A lista de conjuntos finalizados é inválida.',
        );
      }
      namespaces.add(namespace);
    }
    return namespaces;
  }

  Map<String, Object?> _writeTab(LocresWorkspaceTab tab) {
    List<Map<String, Object>> writeEdits(Map<int, String> edits) =>
        edits.entries.map((edit) {
          final entry = tab.document.entries[edit.key];
          return <String, Object>{
            'index': edit.key,
            'fullKey': entry.fullKey,
            'sourceStringHash': entry.sourceStringHash,
            'text': edit.value,
          };
        }).toList();
    return {
      'path': tab.path,
      'projectName': tab.projectName,
      'sourceType': tab.sourceType.name,
      'lastSavedPath': tab.lastSavedPath,
      'selectedNamespace': tab.selectedNamespace,
      'aliases': tab.aliases,
      'edits': writeEdits(tab.currentEdits),
      'savedEdits': writeEdits(tab.savedEdits),
      'finalizedNamespaces': tab.finalizedNamespaces.toList()..sort(),
    };
  }
}
