import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locres_hub/locres_codec.dart';
import 'package:locres_hub/workspace_store.dart';

void main() {
  test(
    'persists project names, aliases, active tab and unsaved edits',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'locres-hub-test-',
      );
      addTearDown(() => directory.delete(recursive: true));

      final entry = LocresEntry(
        namespace: 'UI',
        key: 'Play',
        originalText: 'Play',
        sourceStringHash: 7,
        wasUtf16: false,
        textOffset: 0,
      )..editedText = 'Jogar';
      final tab = LocresWorkspaceTab(
        path: 'C:\\Projects\\Game\\Content\\UI.locres',
        projectName: 'Meu jogo',
        document: LocresDocument(
          originalBytes: Uint8List(0),
          version: 0,
          poolOffset: null,
          poolEnd: null,
          pool: [],
          entries: [entry],
        ),
        aliases: {'UI': 'Interface'},
        finalizedNamespaces: {'UI'},
        selectedNamespace: 'UI',
        lastSavedPath: 'C:\\Projects\\Game\\UI-editado.locres',
      );
      tab.markSaved();
      entry.editedText = 'Jogar agora';
      expect(tab.hasUnsavedChanges, isTrue);
      final store = WorkspaceStore(directory: directory);

      await store.save([tab], tab, themeMode: ThemeMode.dark);
      final snapshot = await store.load();
      final restored = snapshot.tabs.single;

      expect(snapshot.activePath, tab.path);
      expect(snapshot.themeMode, ThemeMode.dark);
      expect(restored.projectName, 'Meu jogo');
      expect(restored.aliases['UI'], 'Interface');
      expect(restored.finalizedNamespaces, {'UI'});
      expect(restored.selectedNamespace, 'UI');
      expect(restored.lastSavedPath, tab.lastSavedPath);
      expect(restored.edits.single.text, 'Jogar agora');
      expect(restored.savedEdits.single.text, 'Jogar');
      expect(restored.edits.single.fullKey, 'UI::Play');
      expect(restored.edits.single.sourceStringHash, 7);

      await store.save(
        [],
        null,
        knownFiles: snapshot.knownFiles,
        themeMode: snapshot.themeMode,
      );
      final closedWorkspace = await store.load();
      expect(closedWorkspace.tabs, isEmpty);
      expect(closedWorkspace.themeMode, ThemeMode.dark);
      expect(closedWorkspace.knownFiles.single.projectName, 'Meu jogo');
      expect(closedWorkspace.knownFiles.single.aliases['UI'], 'Interface');
      expect(closedWorkspace.knownFiles.single.finalizedNamespaces, {'UI'});

      final csvTab = LocresWorkspaceTab(
        path: 'C:\\Projects\\Game\\UI.csv',
        projectName: 'Planilha',
        document: LocresDocument(
          originalBytes: Uint8List(0),
          version: 0,
          poolOffset: null,
          poolEnd: null,
          pool: [],
          entries: [],
        ),
        aliases: {},
        sourceType: WorkspaceSourceType.csv,
      );
      await store.save([csvTab], csvTab);
      expect(
        (await store.load()).tabs.single.sourceType,
        WorkspaceSourceType.csv,
      );
    },
  );
}
