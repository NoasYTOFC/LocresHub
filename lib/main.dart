import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'locres_codec.dart';
import 'locres_csv.dart';
import 'workspace_store.dart';

void main() {
  runApp(const LocresHubApp());
}

class LocresHubApp extends StatefulWidget {
  const LocresHubApp({super.key});

  @override
  State<LocresHubApp> createState() => _LocresHubAppState();
}

class _LocresHubAppState extends State<LocresHubApp> {
  ThemeMode _themeMode = ThemeMode.system;

  void _setThemeMode(ThemeMode mode) {
    if (_themeMode == mode) return;
    setState(() => _themeMode = mode);
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xff6750a4);
    return MaterialApp(
      title: 'Locres Hub',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(seed, Brightness.light),
      darkTheme: _buildTheme(seed, Brightness.dark),
      themeMode: _themeMode,
      home: LocresHomePage(onThemeModeChanged: _setThemeMode),
    );
  }

  ThemeData _buildTheme(Color seed, Brightness brightness) {
    final colors = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: colors,
      useMaterial3: true,
      scaffoldBackgroundColor: colors.surface,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: brightness == Brightness.light
            ? Colors.white
            : colors.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.primary, width: 1.5),
        ),
      ),
      dividerTheme: DividerThemeData(color: colors.outlineVariant),
    );
  }
}

class LocresHomePage extends StatefulWidget {
  const LocresHomePage({
    super.key,
    this.initialDocument,
    this.initialTabs = const [],
    this.workspaceStore = const WorkspaceStore(),
    this.onThemeModeChanged,
  });

  final LocresDocument? initialDocument;
  final List<LocresWorkspaceTab> initialTabs;
  final WorkspaceStore workspaceStore;
  final ValueChanged<ThemeMode>? onThemeModeChanged;

  @override
  State<LocresHomePage> createState() => _LocresHomePageState();
}

enum _EditFilter { all, edited, notEdited }

enum _CloseTabChoice { cancel, discard, save }

class _AliasDialogResult {
  const _AliasDialogResult.save(this.value) : remove = false;
  const _AliasDialogResult.remove() : value = '', remove = true;

  final String value;
  final bool remove;
}

class _GroupProgress {
  const _GroupProgress({required this.total, required this.edited});

  final int total;
  final int edited;
}

class _LocresHomePageState extends State<LocresHomePage>
    with WidgetsBindingObserver {
  final _groupSearchController = TextEditingController();
  final _textSearchController = TextEditingController();
  final List<LocresWorkspaceTab> _tabs = [];
  final Map<String, SavedLocresMetadata> _knownFiles = {};
  LocresWorkspaceTab? _activeTab;
  String? _selectedNamespace;
  String _groupFilter = '';
  String _textFilter = '';
  _EditFilter _editFilter = _EditFilter.all;
  ThemeMode _themeMode = ThemeMode.system;
  bool _isOpening = false;
  bool _isSaving = false;
  bool _isCsvBusy = false;
  bool _isRestoring = false;
  bool _persistenceEnabled = true;
  Timer? _persistenceTimer;

  LocresDocument? get _document => _activeTab?.document;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final document = widget.initialDocument;
    if (document != null) {
      _persistenceEnabled = false;
      _activeTab = LocresWorkspaceTab(
        path: 'example.locres',
        projectName: 'Exemplo',
        document: document,
        aliases: {},
        selectedNamespace: document.entries.isEmpty
            ? null
            : document.entries.first.namespace,
      );
      _tabs.add(_activeTab!);
      _selectedNamespace = document.entries.isEmpty
          ? null
          : document.entries.first.namespace;
    } else if (widget.initialTabs.isNotEmpty) {
      _persistenceEnabled = false;
      _tabs.addAll(widget.initialTabs.take(5));
      _activeTab = _tabs.first;
      _selectedNamespace = _restoredSelection(_activeTab);
    } else {
      _isRestoring = true;
      unawaited(_restoreWorkspace());
    }
  }

  List<LocresEntry> get _visibleEntries {
    final entries = _document?.entries ?? const <LocresEntry>[];
    final query = _textFilter.trim().toLowerCase();
    return entries.where((entry) {
      return entry.namespace == _selectedNamespace &&
          (query.isEmpty ||
              entry.originalText.toLowerCase().contains(query) ||
              entry.editedText.toLowerCase().contains(query)) &&
          switch (_editFilter) {
            _EditFilter.all => true,
            _EditFilter.edited => entry.editedText != entry.originalText,
            _EditFilter.notEdited => entry.editedText == entry.originalText,
          };
    }).toList();
  }

  Map<String, _GroupProgress> get _visibleGroups {
    final groups = <String, _GroupProgress>{};
    final entries = _document?.entries ?? const <LocresEntry>[];
    final query = _groupFilter.trim().toLowerCase();
    for (final entry in entries) {
      final alias = _activeTab?.aliases[entry.namespace]?.toLowerCase() ?? '';
      if (query.isNotEmpty &&
          !entry.namespace.toLowerCase().contains(query) &&
          !alias.contains(query)) {
        continue;
      }
      final current = groups[entry.namespace];
      groups[entry.namespace] = _GroupProgress(
        total: (current?.total ?? 0) + 1,
        edited:
            (current?.edited ?? 0) +
            (entry.editedText != entry.originalText ? 1 : 0),
      );
    }
    return groups;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_persistWorkspace());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _persistenceTimer?.cancel();
    if (_persistenceEnabled) unawaited(_persistWorkspace());
    _groupSearchController.dispose();
    _textSearchController.dispose();
    super.dispose();
  }

  Future<void> _restoreWorkspace() async {
    final restoredTabs = <LocresWorkspaceTab>[];
    final restoredKnownFiles = <String, SavedLocresMetadata>{};
    final warnings = <String>[];
    String? activePath;
    var restoredThemeMode = ThemeMode.system;
    try {
      final snapshot = await widget.workspaceStore.load();
      activePath = snapshot.activePath;
      restoredThemeMode = snapshot.themeMode;
      for (final metadata in snapshot.knownFiles) {
        restoredKnownFiles[_pathKey(metadata.path)] = metadata;
      }
      for (final record in snapshot.tabs) {
        try {
          final bytes = await File(record.path).readAsBytes();
          final document = record.sourceType == WorkspaceSourceType.csv
              ? LocresCsv.parseDocument(utf8.decode(bytes))
              : LocresCodec.parse(bytes);
          var unmatchedEdits = 0;
          for (final edit in record.edits) {
            if (edit.index < 0 || edit.index >= document.entries.length) {
              unmatchedEdits++;
              continue;
            }
            final entry = document.entries[edit.index];
            if (entry.fullKey != edit.fullKey ||
                entry.sourceStringHash != edit.sourceStringHash) {
              unmatchedEdits++;
              continue;
            }
            entry.editedText = edit.text;
          }
          final savedEditValues = <int, String>{};
          for (final edit in record.savedEdits) {
            if (edit.index < 0 || edit.index >= document.entries.length) {
              unmatchedEdits++;
              continue;
            }
            final entry = document.entries[edit.index];
            if (entry.fullKey != edit.fullKey ||
                entry.sourceStringHash != edit.sourceStringHash) {
              unmatchedEdits++;
              continue;
            }
            savedEditValues[edit.index] = edit.text;
          }
          if (unmatchedEdits > 0) {
            warnings.add(
              '${record.projectName}: $unmatchedEdits edição(ões) não corresponderam ao arquivo atual.',
            );
          }
          restoredTabs.add(
            LocresWorkspaceTab(
              path: record.path,
              projectName: record.projectName,
              document: document,
              aliases: Map<String, String>.from(record.aliases),
              sourceType: record.sourceType,
              finalizedNamespaces: Set<String>.from(record.finalizedNamespaces),
              selectedNamespace: record.selectedNamespace,
              lastSavedPath: record.lastSavedPath,
              savedEdits: savedEditValues,
            ),
          );
        } on FileSystemException catch (error) {
          warnings.add('${record.path}: ${error.message}');
        } on FormatException catch (error) {
          warnings.add('${record.path}: ${error.message}');
        }
      }
    } on FileSystemException catch (error) {
      warnings.add(
        'Não foi possível ler o espaço de trabalho: ${error.message}',
      );
    } on FormatException catch (error) {
      warnings.add(
        'Não foi possível ler o espaço de trabalho: ${error.message}',
      );
    } on PlatformException catch (error) {
      warnings.add(
        'Não foi possível acessar o armazenamento local: ${error.message}',
      );
    }
    if (!mounted) return;
    LocresWorkspaceTab? selectedTab;
    for (final tab in restoredTabs) {
      if (activePath != null && _samePath(tab.path, activePath)) {
        selectedTab = tab;
        break;
      }
      restoredKnownFiles[_pathKey(tab.path)] = SavedLocresMetadata(
        path: tab.path,
        projectName: tab.projectName,
        aliases: Map<String, String>.from(tab.aliases),
        finalizedNamespaces: Set<String>.from(tab.finalizedNamespaces),
      );
    }
    if (selectedTab != null) {
      restoredKnownFiles[_pathKey(selectedTab.path)] = SavedLocresMetadata(
        path: selectedTab.path,
        projectName: selectedTab.projectName,
        aliases: Map<String, String>.from(selectedTab.aliases),
        finalizedNamespaces: Set<String>.from(selectedTab.finalizedNamespaces),
      );
    }
    setState(() {
      _tabs
        ..clear()
        ..addAll(restoredTabs.take(5));
      _knownFiles
        ..clear()
        ..addAll(restoredKnownFiles);
      _activeTab = selectedTab ?? (_tabs.isEmpty ? null : _tabs.first);
      _selectedNamespace = _restoredSelection(_activeTab);
      _themeMode = restoredThemeMode;
      _isRestoring = false;
    });
    widget.onThemeModeChanged?.call(restoredThemeMode);
    if (warnings.isNotEmpty) {
      _showMessage(warnings.first);
    }
  }

  String? _restoredSelection(LocresWorkspaceTab? tab) {
    final selection = tab?.selectedNamespace;
    if (selection != null &&
        tab!.document.entries.any((entry) => entry.namespace == selection)) {
      return selection;
    }
    return tab?.document.entries.isEmpty == true
        ? null
        : tab?.document.entries.first.namespace;
  }

  bool _samePath(String first, String second) =>
      _pathKey(first) == _pathKey(second);

  String _pathKey(String path) =>
      path.replaceAll('/', Platform.pathSeparator).toLowerCase();

  void _scheduleWorkspaceSave() {
    if (!_persistenceEnabled || _isRestoring) return;
    _persistenceTimer?.cancel();
    _persistenceTimer = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(_persistWorkspace()),
    );
  }

  Future<void> _persistWorkspace() async {
    if (!_persistenceEnabled || _isRestoring) return;
    _persistenceTimer?.cancel();
    _persistenceTimer = null;
    try {
      await widget.workspaceStore.save(
        _tabs,
        _activeTab,
        knownFiles: _knownFiles.values.toList(growable: false),
        themeMode: _themeMode,
      );
    } on FileSystemException catch (error) {
      _showMessage(
        'Não foi possível salvar o espaço de trabalho: ${error.message}',
      );
    } on PlatformException catch (error) {
      _showMessage(
        'Não foi possível acessar o armazenamento local: ${error.message}',
      );
    }
  }

  void _setThemeMode(ThemeMode mode) {
    if (_themeMode == mode) return;
    setState(() => _themeMode = mode);
    widget.onThemeModeChanged?.call(mode);
    _scheduleWorkspaceSave();
  }

  Future<String?> _askProjectName(String path, {String? existingName}) async {
    final defaultName =
        existingName ??
        path
            .split(Platform.pathSeparator)
            .last
            .replaceFirst(RegExp(r'\.(locres|csv)$', caseSensitive: false), '');
    return showDialog<String>(
      context: context,
      builder: (context) => _ProjectNameDialog(defaultName: defaultName),
    );
  }

  Future<void> _openFile() async {
    if (_isOpening || _isRestoring) return;
    setState(() => _isOpening = true);
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: 'Abrir arquivo Locres',
        type: FileType.custom,
        allowedExtensions: const ['locres'],
      );
      if (file == null) return;
      final path = file.path;
      if (path == null) return;

      final existingIndex = _tabs.indexWhere(
        (tab) => _samePath(tab.path, path),
      );
      if (existingIndex >= 0) {
        _switchTab(existingIndex);
        return;
      }
      if (_tabs.length >= 5) {
        _showMessage('O limite de cinco arquivos Locres já está aberto.');
        return;
      }

      final document = LocresCodec.parse(await File(path).readAsBytes());
      final metadata = _knownFiles[_pathKey(path)];
      final projectName = await _askProjectName(
        path,
        existingName: metadata?.projectName,
      );
      if (projectName == null) return;
      if (projectName.trim().isEmpty) {
        _showMessage('Digite um nome para identificar o projeto.');
        return;
      }

      final tab = LocresWorkspaceTab(
        path: path,
        projectName: projectName.trim(),
        document: document,
        aliases: Map<String, String>.from(metadata?.aliases ?? const {}),
        finalizedNamespaces: Set<String>.from(
          metadata?.finalizedNamespaces ?? const {},
        ),
        selectedNamespace: document.entries.isEmpty
            ? null
            : document.entries.first.namespace,
      );
      setState(() {
        _tabs.add(tab);
        _activeTab = tab;
        _selectedNamespace = tab.selectedNamespace;
        _rememberTab(tab);
        _clearSearches();
      });
      _scheduleWorkspaceSave();
    } on FormatException catch (error) {
      _showMessage('Não foi possível abrir o Locres: ${error.message}');
    } on FileSystemException catch (error) {
      _showMessage('Não foi possível ler o arquivo: ${error.message}');
    } on PlatformException catch (error) {
      _showMessage(
        'O seletor de arquivos não conseguiu abrir o arquivo: ${error.message}',
      );
    } finally {
      if (mounted) setState(() => _isOpening = false);
    }
  }

  Future<void> _openCsvForEditing() async {
    if (_isCsvBusy || _isOpening || _isRestoring) return;
    setState(() => _isCsvBusy = true);
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: 'Abrir CSV para edição',
        type: FileType.custom,
        allowedExtensions: const ['csv'],
      );
      if (file == null) return;
      final path = file.path;
      if (path == null) {
        throw const FormatException(
          'O caminho do CSV selecionado não está disponível.',
        );
      }

      final existingIndex = _tabs.indexWhere(
        (tab) => _samePath(tab.path, path),
      );
      if (existingIndex >= 0) {
        _switchTab(existingIndex);
        return;
      }
      if (_tabs.length >= 5) {
        _showMessage('O limite de cinco arquivos abertos já foi atingido.');
        return;
      }

      final document = LocresCsv.parseDocument(
        utf8.decode(await File(path).readAsBytes()),
      );
      final metadata = _knownFiles[_pathKey(path)];
      final projectName = await _askProjectName(
        path,
        existingName: metadata?.projectName,
      );
      if (projectName == null) return;
      if (projectName.trim().isEmpty) {
        _showMessage('Digite um nome para identificar o projeto.');
        return;
      }

      final tab = LocresWorkspaceTab(
        path: path,
        projectName: projectName.trim(),
        document: document,
        aliases: Map<String, String>.from(metadata?.aliases ?? const {}),
        finalizedNamespaces: Set<String>.from(
          metadata?.finalizedNamespaces ?? const {},
        ),
        sourceType: WorkspaceSourceType.csv,
        selectedNamespace: document.entries.isEmpty
            ? null
            : document.entries.first.namespace,
      )..markSaved();
      setState(() {
        _tabs.add(tab);
        _activeTab = tab;
        _selectedNamespace = tab.selectedNamespace;
        _rememberTab(tab);
        _clearSearches();
      });
      _scheduleWorkspaceSave();
    } on FormatException catch (error) {
      _showMessage('Não foi possível abrir o CSV: ${error.message}');
    } on FileSystemException catch (error) {
      _showMessage('Não foi possível ler o CSV: ${error.message}');
    } on PlatformException catch (error) {
      _showMessage('O seletor de arquivos falhou: ${error.message}');
    } finally {
      if (mounted) setState(() => _isCsvBusy = false);
    }
  }

  void _rememberTab(LocresWorkspaceTab tab) {
    _knownFiles[_pathKey(tab.path)] = SavedLocresMetadata(
      path: tab.path,
      projectName: tab.projectName,
      aliases: Map<String, String>.from(tab.aliases),
      finalizedNamespaces: Set<String>.from(tab.finalizedNamespaces),
    );
  }

  void _clearSearches() {
    _groupSearchController.clear();
    _textSearchController.clear();
    _groupFilter = '';
    _textFilter = '';
    _editFilter = _EditFilter.all;
  }

  void _switchTab(int index) {
    final tab = _tabs[index];
    if (identical(_activeTab, tab)) return;
    setState(() {
      _activeTab = tab;
      _selectedNamespace = _restoredSelection(tab);
      _clearSearches();
    });
    _scheduleWorkspaceSave();
  }

  KeyEventResult _handleWorkspaceShortcut(FocusNode node, KeyEvent event) {
    if ((event is! KeyDownEvent && event is! KeyRepeatEvent) ||
        !HardwareKeyboard.instance.isControlPressed) {
      return KeyEventResult.ignored;
    }
    final index = switch (event.logicalKey) {
      LogicalKeyboardKey.digit1 || LogicalKeyboardKey.numpad1 => 0,
      LogicalKeyboardKey.digit2 || LogicalKeyboardKey.numpad2 => 1,
      LogicalKeyboardKey.digit3 || LogicalKeyboardKey.numpad3 => 2,
      LogicalKeyboardKey.digit4 || LogicalKeyboardKey.numpad4 => 3,
      LogicalKeyboardKey.digit5 || LogicalKeyboardKey.numpad5 => 4,
      _ => null,
    };
    if (index == null || index >= _tabs.length) {
      return KeyEventResult.ignored;
    }
    _switchTab(index);
    return KeyEventResult.handled;
  }

  String _safeFileName(String value) =>
      value.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');

  Future<void> _exportEditedCsv() async {
    if (_isCsvBusy || _isOpening) return;
    final tab = _activeTab;
    if (tab == null) {
      _showMessage('Abra um Locres antes de exportar.');
      return;
    }
    final editedEntries = tab.document.entries
        .where((entry) => entry.editedText != entry.originalText)
        .toList(growable: false);
    if (editedEntries.isEmpty) {
      _showMessage('Este Locres ainda não tem textos editados para exportar.');
      return;
    }

    setState(() => _isCsvBusy = true);
    try {
      final result = await FilePicker.saveFile(
        dialogTitle: 'Exportar textos editados para CSV',
        fileName: '${_safeFileName(tab.projectName)}-editados.csv',
        bytes: Uint8List.fromList(
          LocresCsv.exportEntries(editedEntries, editedOnly: true),
        ),
        type: FileType.custom,
        allowedExtensions: const ['csv'],
      );
      if (result != null) {
        _showMessage('CSV exportado com ${editedEntries.length} texto(s).');
      }
    } on FileSystemException catch (error) {
      _showMessage('Não foi possível gravar o CSV: ${error.message}');
    } on PlatformException catch (error) {
      _showMessage(
        'O seletor de arquivos não conseguiu salvar: ${error.message}',
      );
    } finally {
      if (mounted) setState(() => _isCsvBusy = false);
    }
  }

  Future<void> _exportSelectedGroupsCsv() async {
    if (_isCsvBusy || _isOpening) return;
    final tab = _activeTab;
    if (tab == null) {
      _showMessage('Abra um Locres antes de exportar conjuntos.');
      return;
    }
    final namespaces =
        tab.document.entries.map((entry) => entry.namespace).toSet().toList()
          ..sort();
    if (namespaces.isEmpty) {
      _showMessage('Este Locres não contém conjuntos para exportar.');
      return;
    }

    final selectedNamespaces = await showDialog<Set<String>>(
      context: context,
      builder: (context) => _GroupExportDialog(
        namespaces: namespaces,
        aliases: tab.aliases,
        entries: tab.document.entries,
      ),
    );
    if (selectedNamespaces == null || selectedNamespaces.isEmpty) return;

    final entries = tab.document.entries.where(
      (entry) => selectedNamespaces.contains(entry.namespace),
    );
    setState(() => _isCsvBusy = true);
    try {
      final result = await FilePicker.saveFile(
        dialogTitle: 'Exportar conjuntos selecionados para CSV',
        fileName: '${_safeFileName(tab.projectName)}-para-edicao.csv',
        bytes: Uint8List.fromList(
          LocresCsv.exportEntries(entries, editedOnly: false),
        ),
        type: FileType.custom,
        allowedExtensions: const ['csv'],
      );
      if (result != null) {
        _showMessage(
          'CSV criado com ${entries.length} linha(s) dos conjuntos selecionados.',
        );
      }
    } on FileSystemException catch (error) {
      _showMessage('Não foi possível gravar o CSV: ${error.message}');
    } on PlatformException catch (error) {
      _showMessage(
        'O seletor de arquivos não conseguiu salvar: ${error.message}',
      );
    } finally {
      if (mounted) setState(() => _isCsvBusy = false);
    }
  }

  Future<void> _mergeCsvFiles() async {
    if (_isCsvBusy || _isOpening) return;
    setState(() => _isCsvBusy = true);
    try {
      final locresFile = await FilePicker.pickFile(
        dialogTitle: 'Escolha o Locres que receberá as traduções',
        type: FileType.custom,
        allowedExtensions: const ['locres'],
      );
      if (locresFile == null) return;
      final locresPath = locresFile.path;
      if (locresPath == null) {
        throw const FormatException(
          'O caminho do Locres selecionado não está disponível.',
        );
      }
      final existingIndex = _tabs.indexWhere(
        (tab) => _samePath(tab.path, locresPath),
      );
      if (existingIndex < 0 && _tabs.length >= 5) {
        _showMessage(
          'Feche uma aba antes do merge; o limite de cinco arquivos está aberto.',
        );
        return;
      }

      final csvFiles = await FilePicker.pickFiles(
        dialogTitle: 'Selecione um ou mais CSVs para mesclar',
        type: FileType.custom,
        allowedExtensions: const ['csv'],
      );
      if (csvFiles.isEmpty) return;

      final document = existingIndex >= 0
          ? _tabs[existingIndex].document
          : LocresCodec.parse(await File(locresPath).readAsBytes());
      final sources = <LocresCsvSource>[];
      sources.addAll(await _readCsvSources(csvFiles));

      await _applyCsvSources(
        document,
        sources,
        targetPath: locresPath,
        targetTab: existingIndex < 0 ? null : _tabs[existingIndex],
        metadata: _knownFiles[_pathKey(locresPath)],
        operationName: 'Merge',
      );
    } on FormatException catch (error) {
      _showMessage('Não foi possível mesclar os arquivos: ${error.message}');
    } on FileSystemException catch (error) {
      _showMessage('Não foi possível ler um dos arquivos: ${error.message}');
    } on PlatformException catch (error) {
      _showMessage('O seletor de arquivos falhou: ${error.message}');
    } finally {
      if (mounted) setState(() => _isCsvBusy = false);
    }
  }

  Future<void> _importCsvIntoActiveTab() async {
    if (_isCsvBusy || _isOpening) return;
    final tab = _activeTab;
    if (tab == null) {
      _showMessage('Abra o Locres que receberá o CSV primeiro.');
      return;
    }
    setState(() => _isCsvBusy = true);
    try {
      final csvFiles = await FilePicker.pickFiles(
        dialogTitle: 'Selecione um ou mais CSVs para importar',
        type: FileType.custom,
        allowedExtensions: const ['csv'],
      );
      if (csvFiles.isEmpty) return;
      final sources = await _readCsvSources(csvFiles);
      await _applyCsvSources(
        tab.document,
        sources,
        targetPath: tab.path,
        targetTab: tab,
        metadata: _knownFiles[_pathKey(tab.path)],
        operationName: 'Importação CSV',
      );
    } on FormatException catch (error) {
      _showMessage('Não foi possível importar o CSV: ${error.message}');
    } on FileSystemException catch (error) {
      _showMessage('Não foi possível ler um dos arquivos: ${error.message}');
    } on PlatformException catch (error) {
      _showMessage('O seletor de arquivos falhou: ${error.message}');
    } finally {
      if (mounted) setState(() => _isCsvBusy = false);
    }
  }

  Future<List<LocresCsvSource>> _readCsvSources(
    List<PlatformFile> csvFiles,
  ) async {
    final sources = <LocresCsvSource>[];
    for (final csvFile in csvFiles) {
      final path = csvFile.path;
      if (path == null) {
        throw FormatException(
          'O caminho do CSV "${csvFile.name}" não está disponível.',
        );
      }
      sources.add(
        LocresCsvSource(
          name: csvFile.name,
          content: utf8.decode(await File(path).readAsBytes()),
        ),
      );
    }
    return sources;
  }

  Future<void> _applyCsvSources(
    LocresDocument document,
    List<LocresCsvSource> sources, {
    required String targetPath,
    required String operationName,
    LocresWorkspaceTab? targetTab,
    SavedLocresMetadata? metadata,
  }) async {
    final plan = LocresCsv.prepareMerge(document, sources);
    final selections = await _resolveCsvConflicts(plan.conflicts);
    if (selections == null) return;
    final resolved = LocresCsv.resolveConflicts(plan, selections);
    if (resolved.isEmpty) {
      _showMessage(
        plan.unmatchedRows == 0
            ? 'Os CSVs não contêm traduções preenchidas para aplicar.'
            : 'Nenhuma linha correspondeu ao Locres. Confira as chaves e os hashes dos CSVs.',
      );
      return;
    }

    final entriesById = <LocresCsvEntryId, LocresEntry>{};
    for (final entry in document.entries) {
      entriesById[_csvEntryId(entry)] = entry;
    }
    final changes = resolved.entries
        .where(
          (change) =>
              entriesById[change.key]!.editedText != change.value.edited,
        )
        .toList(growable: false);
    if (changes.isEmpty) {
      _showMessage('Os textos do Locres já correspondem aos valores dos CSVs.');
      return;
    }

    final tab =
        targetTab ?? await _createTabForMerge(targetPath, document, metadata);
    if (tab == null || !mounted) return;

    setState(() {
      for (final change in changes) {
        entriesById[change.key]!.editedText = change.value.edited;
      }
      if (!_tabs.contains(tab)) _tabs.add(tab);
      _activeTab = tab;
      _selectedNamespace = changes.first.key.namespace;
      tab.selectedNamespace = _selectedNamespace;
      _clearSearches();
      _rememberTab(tab);
    });
    _scheduleWorkspaceSave();
    final unmatched = plan.unmatchedRows == 0
        ? ''
        : ' ${plan.unmatchedRows} linha(s) não corresponderam ao Locres.';
    _showMessage(
      '$operationName aplicado: ${changes.length} texto(s) alterado(s). Salve uma cópia para gerar o Locres atualizado.$unmatched',
    );
  }

  LocresCsvEntryId _csvEntryId(LocresEntry entry) => (
    namespace: entry.namespace,
    key: entry.key,
    sourceStringHash: entry.sourceStringHash,
  );

  Future<LocresWorkspaceTab?> _createTabForMerge(
    String path,
    LocresDocument document,
    SavedLocresMetadata? metadata,
  ) async {
    final projectName = await _askProjectName(
      path,
      existingName: metadata?.projectName,
    );
    if (projectName == null) return null;
    if (projectName.trim().isEmpty) {
      _showMessage('Digite um nome para identificar o projeto.');
      return null;
    }
    return LocresWorkspaceTab(
      path: path,
      projectName: projectName.trim(),
      document: document,
      aliases: Map<String, String>.from(metadata?.aliases ?? const {}),
      finalizedNamespaces: Set<String>.from(
        metadata?.finalizedNamespaces ?? const {},
      ),
      selectedNamespace: document.entries.isEmpty
          ? null
          : document.entries.first.namespace,
    );
  }

  Future<Map<LocresCsvEntryId, String>?> _resolveCsvConflicts(
    List<LocresCsvConflict> conflicts,
  ) async {
    if (conflicts.isEmpty) return const {};
    final selectedValues = <LocresCsvEntryId, String>{};
    return showDialog<Map<LocresCsvEntryId, String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          icon: const Icon(Icons.compare_arrows_rounded),
          title: Text('${conflicts.length} conflito(s) entre CSVs'),
          content: SizedBox(
            width: 650,
            height: 480,
            child: Column(
              children: [
                const Text(
                  'Escolha qual tradução usar para cada chave repetida.',
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.separated(
                    itemCount: conflicts.length,
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final conflict = conflicts[index];
                      final namespace = conflict.id.namespace.isEmpty
                          ? '(sem conjunto)'
                          : conflict.id.namespace;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$namespace::${conflict.id.key}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 5),
                            DropdownButton<String>(
                              isExpanded: true,
                              value: selectedValues[conflict.id],
                              hint: const Text('Selecione uma tradução'),
                              items: conflict.values
                                  .map(
                                    (value) => DropdownMenuItem(
                                      value: value.edited,
                                      child: Text(
                                        '${value.edited}  —  ${value.sourceName}',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (value) {
                                if (value == null) return;
                                setDialogState(
                                  () => selectedValues[conflict.id] = value,
                                );
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar merge'),
            ),
            FilledButton(
              onPressed: selectedValues.length == conflicts.length
                  ? () => Navigator.pop(
                      context,
                      Map<LocresCsvEntryId, String>.from(selectedValues),
                    )
                  : null,
              child: const Text('Usar seleções'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveFile() async {
    final tab = _activeTab;
    if (tab == null || _isSaving) return;
    if (!tab.hasUnsavedChanges) {
      _showMessage('Nenhuma alteração para salvar.');
      return;
    }
    await _saveTab(tab);
  }

  Future<bool> _saveTab(LocresWorkspaceTab tab) async {
    setState(() => _isSaving = true);
    try {
      final isCsv = tab.sourceType == WorkspaceSourceType.csv;
      final extension = isCsv ? 'csv' : 'locres';
      final suggestedName = tab.lastSavedPath != null
          ? tab.lastSavedPath!.split(Platform.pathSeparator).last
          : '${tab.fileName.replaceFirst(RegExp(r'\.(locres|csv)$', caseSensitive: false), '')}-editado.$extension';
      final savedUri = await FilePicker.saveFile(
        dialogTitle: isCsv ? 'Salvar cópia do CSV' : 'Salvar cópia do Locres',
        fileName: suggestedName,
        bytes: isCsv
            ? Uint8List.fromList(
                LocresCsv.exportEntries(
                  tab.document.entries,
                  editedOnly: false,
                ),
              )
            : LocresCodec.serialize(tab.document),
        type: FileType.custom,
        allowedExtensions: [extension],
      );
      if (savedUri == null) return false;
      tab.lastSavedPath = savedUri.toFilePath();
      tab.markSaved();
      if (mounted) {
        setState(() {});
        _showMessage(
          'Cópia ${isCsv ? 'CSV' : 'Locres'} salva em ${tab.lastSavedPath!.split(Platform.pathSeparator).last}.',
        );
      }
      _scheduleWorkspaceSave();
      return true;
    } on FormatException catch (error) {
      _showMessage('Não foi possível salvar o arquivo: ${error.message}');
    } on FileSystemException catch (error) {
      _showMessage('Erro ao gravar o arquivo: ${error.message}');
    } on PlatformException catch (error) {
      _showMessage(
        'O seletor de arquivos não conseguiu salvar: ${error.message}',
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
    return false;
  }

  Future<void> _closeTab(LocresWorkspaceTab tab) async {
    if (tab.hasUnsavedChanges) {
      final choice = await showDialog<_CloseTabChoice>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Este projeto tem alterações pendentes'),
          content: Text(
            'O projeto “${tab.projectName}” ainda tem textos não salvos.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, _CloseTabChoice.cancel),
              child: const Text('Continuar editando'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, _CloseTabChoice.discard),
              child: const Text('Descartar e fechar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, _CloseTabChoice.save),
              child: const Text('Salvar cópia e fechar'),
            ),
          ],
        ),
      );
      if (choice == null || choice == _CloseTabChoice.cancel) return;
      if (choice == _CloseTabChoice.save && !await _saveTab(tab)) return;
    }

    final closingIndex = _tabs.indexOf(tab);
    final wasActive = identical(tab, _activeTab);
    setState(() {
      _tabs.remove(tab);
      if (wasActive) {
        _activeTab = _tabs.isEmpty
            ? null
            : _tabs[closingIndex.clamp(0, _tabs.length - 1)];
        _selectedNamespace = _restoredSelection(_activeTab);
        _clearSearches();
      }
    });
    _scheduleWorkspaceSave();
  }

  void _selectNamespace(String namespace) {
    if (_selectedNamespace == namespace) return;
    setState(() {
      _selectedNamespace = namespace;
      _activeTab?.selectedNamespace = namespace;
      _textSearchController.clear();
      _textFilter = '';
      _editFilter = _EditFilter.all;
    });
    _scheduleWorkspaceSave();
  }

  void _toggleGroupFinalized(String namespace) {
    final tab = _activeTab;
    if (tab == null) return;
    setState(() {
      if (!tab.finalizedNamespaces.add(namespace)) {
        tab.finalizedNamespaces.remove(namespace);
      }
      _rememberTab(tab);
    });
    _scheduleWorkspaceSave();
  }

  void _editEntryText(LocresEntry entry, String value) {
    setState(() {
      entry.editedText = value;
      if ((_editFilter == _EditFilter.notEdited &&
              value != entry.originalText) ||
          (_editFilter == _EditFilter.edited && value == entry.originalText)) {
        _editFilter = _EditFilter.all;
      }
    });
    _scheduleWorkspaceSave();
  }

  void _updateGroupFilter(String value) {
    setState(() {
      _groupFilter = value;
      final groups = _visibleGroups;
      if (groups.isNotEmpty && !groups.containsKey(_selectedNamespace)) {
        _selectedNamespace = groups.keys.first;
        _activeTab?.selectedNamespace = _selectedNamespace;
        _textSearchController.clear();
        _textFilter = '';
        _editFilter = _EditFilter.all;
      } else if (groups.isEmpty) {
        _selectedNamespace = null;
        _activeTab?.selectedNamespace = null;
        _textSearchController.clear();
        _textFilter = '';
        _editFilter = _EditFilter.all;
      }
    });
    _scheduleWorkspaceSave();
  }

  void _updateTextFilter(String value) {
    setState(() => _textFilter = value);
  }

  void _setEditFilter(_EditFilter filter) {
    setState(() => _editFilter = filter);
  }

  Future<void> _editGroupAlias(String namespace) async {
    final tab = _activeTab;
    if (tab == null) return;
    final result = await showDialog<_AliasDialogResult>(
      context: context,
      builder: (context) => _AliasEditDialog(
        namespace: namespace,
        alias: tab.aliases[namespace] ?? '',
      ),
    );
    if (result == null) return;

    setState(() {
      final alias = result.value.trim();
      if (result.remove || alias.isEmpty) {
        tab.aliases.remove(namespace);
      } else {
        tab.aliases[namespace] = alias;
      }
      _rememberTab(tab);
    });
    _scheduleWorkspaceSave();
  }

  void _removeGroupAlias(String namespace) {
    final tab = _activeTab;
    if (tab == null || !tab.aliases.containsKey(namespace)) return;
    setState(() {
      tab.aliases.remove(namespace);
      _rememberTab(tab);
    });
    _scheduleWorkspaceSave();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showGuide() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.school_outlined),
        title: const Text('Guia rápido: arquivos Locres'),
        content: const SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _GuideStep(
                  number: '1',
                  title: 'Abra um arquivo .locres',
                  description:
                      'Escolha um arquivo de localização e dê um nome ao projeto. É possível manter até cinco Locres abertos em abas.',
                ),
                _GuideStep(
                  number: '2',
                  title: 'Encontre um conjunto',
                  description:
                      'A busca da esquerda filtra somente conjuntos. Clique com o botão direito para adicionar ou remover um apelido, que também pode ser pesquisado.',
                ),
                _GuideStep(
                  number: '3',
                  title: 'Pesquise e edite textos',
                  description:
                      'A busca da direita filtra somente o texto do conjunto selecionado. Use os filtros “Editados” e “Não editados”; cada linha mostra o original ao lado do campo editável.',
                ),
                _GuideStep(
                  number: '4',
                  title: 'Salve uma cópia',
                  description:
                      'Salvar cria um novo arquivo terminado em “-editado.locres”; o original permanece intacto. Teste a cópia no seu projeto antes de distribuir.',
                ),
                _GuideStep(
                  number: '5',
                  title: 'Troque traduções por CSV',
                  description:
                      'No menu CSV, exporte apenas os textos editados ou escolha conjuntos para criar uma planilha de edição. “Abrir CSV para edição” cria uma aba sem exigir um Locres; edite e salve de volta como CSV para devolver à equipe. Também é possível importar CSVs na aba ativa ou escolher outro Locres no merge.',
                ),
                SizedBox(height: 12),
                Text(
                  'Use as setas ↑/↓ em um campo de edição para ir para o texto anterior ou seguinte. Ctrl+1 até Ctrl+5 troca para uma aba aberta. O tema pode seguir o sistema ou ser fixado em claro/escuro. Apelidos, nomes de projeto, abas e edições pendentes são restaurados localmente.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Entendi'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final document = _document;
    final selectedNamespace = _selectedNamespace;
    final activeTab = _activeTab;

    return Focus(
      autofocus: true,
      onKeyEvent: _handleWorkspaceShortcut,
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              _TopBar(
                fileName: activeTab == null
                    ? null
                    : '${activeTab.projectName} — ${activeTab.fileName}',
                isDirty: activeTab?.hasUnsavedChanges ?? false,
                isCsvTab: activeTab?.sourceType == WorkspaceSourceType.csv,
                isSaving: _isSaving,
                isBusy: _isOpening || _isRestoring || _isCsvBusy,
                isCsvBusy: _isCsvBusy,
                canOpen: true,
                canSave: !_isCsvBusy && (activeTab?.hasUnsavedChanges ?? false),
                canExportEdited:
                    activeTab?.document.entries.any(
                      (entry) => entry.editedText != entry.originalText,
                    ) ??
                    false,
                canExportGroups:
                    activeTab?.document.entries.isNotEmpty ?? false,
                canImportCsv: activeTab != null,
                themeMode: _themeMode,
                onThemeModeChanged: _setThemeMode,
                onOpen: _openFile,
                onSave: _saveFile,
                onExportEdited: _exportEditedCsv,
                onExportGroups: _exportSelectedGroupsCsv,
                onImportCsv: _importCsvIntoActiveTab,
                onOpenCsv: _openCsvForEditing,
                onMergeCsv: _mergeCsvFiles,
                onHelp: _showGuide,
              ),
              _WorkspaceTabs(
                tabs: _tabs,
                activeTab: activeTab,
                onSelect: _switchTab,
                onClose: _closeTab,
              ),
              Expanded(
                child: Row(
                  children: [
                    SizedBox(
                      width: 320,
                      child: _Sidebar(
                        document: document,
                        groups: _visibleGroups,
                        selectedNamespace: selectedNamespace,
                        aliases: activeTab?.aliases ?? const <String, String>{},
                        finalizedNamespaces:
                            activeTab?.finalizedNamespaces ?? const {},
                        searchController: _groupSearchController,
                        isOpening: _isOpening || _isRestoring || _isCsvBusy,
                        onSearchChanged: _updateGroupFilter,
                        onOpen: _openFile,
                        onSelect: _selectNamespace,
                        onToggleFinalized: _toggleGroupFinalized,
                        onEditAlias: _editGroupAlias,
                        onRemoveAlias: _removeGroupAlias,
                      ),
                    ),
                    const VerticalDivider(width: 1, thickness: 1),
                    Expanded(
                      child: document == null
                          ? const _WelcomePanel()
                          : selectedNamespace == null
                          ? _NoGroupSelectionPanel(
                              hasEntries: document.entries.isNotEmpty,
                            )
                          : _GroupEditor(
                              namespace: selectedNamespace,
                              version: document.versionLabel,
                              entries: _visibleEntries,
                              searchController: _textSearchController,
                              onSearchChanged: _updateTextFilter,
                              editFilter: _editFilter,
                              onEditFilterChanged: _setEditFilter,
                              allEntries: document.entries
                                  .where(
                                    (entry) =>
                                        entry.namespace == selectedNamespace,
                                  )
                                  .toList(),
                              alias: activeTab?.aliases[selectedNamespace],
                              onChanged: _editEntryText,
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.fileName,
    required this.isDirty,
    required this.isCsvTab,
    required this.isSaving,
    required this.isBusy,
    required this.isCsvBusy,
    required this.canOpen,
    required this.canSave,
    required this.canExportEdited,
    required this.canExportGroups,
    required this.canImportCsv,
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.onOpen,
    required this.onSave,
    required this.onExportEdited,
    required this.onExportGroups,
    required this.onImportCsv,
    required this.onOpenCsv,
    required this.onMergeCsv,
    required this.onHelp,
  });

  final String? fileName;
  final bool isDirty;
  final bool isCsvTab;
  final bool isSaving;
  final bool isBusy;
  final bool isCsvBusy;
  final bool canOpen;
  final bool canSave;
  final bool canExportEdited;
  final bool canExportGroups;
  final bool canImportCsv;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final VoidCallback onOpen;
  final VoidCallback onSave;
  final VoidCallback onExportEdited;
  final VoidCallback onExportGroups;
  final VoidCallback onImportCsv;
  final VoidCallback onOpenCsv;
  final VoidCallback onMergeCsv;
  final VoidCallback onHelp;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(13),
            child: Image.asset(
              'assets/icon.png',
              width: 42,
              height: 42,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 12),
          const Text(
            'Locres Hub',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              fileName ??
                  'Editor didático de arquivos de localização da Unreal',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ),
          IconButton(
            tooltip: 'Guia rápido',
            onPressed: onHelp,
            icon: const Icon(Icons.help_outline_rounded),
          ),
          PopupMenuButton<ThemeMode>(
            tooltip: 'Tema: ${_themeModeLabel(themeMode)}',
            onSelected: onThemeModeChanged,
            icon: Icon(switch (themeMode) {
              ThemeMode.system => Icons.brightness_6_outlined,
              ThemeMode.light => Icons.light_mode_outlined,
              ThemeMode.dark => Icons.dark_mode_outlined,
            }),
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                value: ThemeMode.system,
                checked: themeMode == ThemeMode.system,
                child: const Text('Seguir o sistema'),
              ),
              CheckedPopupMenuItem(
                value: ThemeMode.light,
                checked: themeMode == ThemeMode.light,
                child: const Text('Claro'),
              ),
              CheckedPopupMenuItem(
                value: ThemeMode.dark,
                checked: themeMode == ThemeMode.dark,
                child: const Text('Escuro'),
              ),
            ],
          ),
          PopupMenuButton<String>(
            tooltip: 'CSV e merge',
            enabled: !isBusy && !isCsvBusy,
            onSelected: (action) {
              switch (action) {
                case 'exportEdited':
                  onExportEdited();
                case 'exportGroups':
                  onExportGroups();
                case 'importCsv':
                  onImportCsv();
                case 'openCsv':
                  onOpenCsv();
                case 'merge':
                  onMergeCsv();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'exportEdited',
                enabled: canExportEdited && !isCsvBusy,
                child: const ListTile(
                  dense: true,
                  leading: Icon(Icons.file_upload_outlined),
                  title: Text('Exportar textos editados'),
                ),
              ),
              PopupMenuItem(
                value: 'exportGroups',
                enabled: canExportGroups && !isCsvBusy,
                child: const ListTile(
                  dense: true,
                  leading: Icon(Icons.library_add_check_outlined),
                  title: Text('Criar CSV por conjuntos...'),
                ),
              ),
              PopupMenuItem(
                value: 'importCsv',
                enabled: canImportCsv && !isCsvBusy,
                child: const ListTile(
                  dense: true,
                  leading: Icon(Icons.file_download_outlined),
                  title: Text('Importar CSVs na aba atual'),
                ),
              ),
              PopupMenuItem(
                value: 'openCsv',
                enabled: !isBusy && !isCsvBusy,
                child: const ListTile(
                  dense: true,
                  leading: Icon(Icons.table_view_outlined),
                  title: Text('Abrir CSV para edição...'),
                ),
              ),
              PopupMenuItem(
                value: 'merge',
                enabled: !isCsvBusy,
                child: const ListTile(
                  dense: true,
                  leading: Icon(Icons.merge_type_rounded),
                  title: Text('Merge Locres + CSVs...'),
                ),
              ),
            ],
            icon: isCsvBusy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.table_chart_outlined),
          ),
          const SizedBox(width: 4),
          OutlinedButton.icon(
            onPressed: isBusy || !canOpen ? null : onOpen,
            icon: const Icon(Icons.folder_open_outlined, size: 18),
            label: const Text('Abrir'),
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: isSaving || !canSave ? null : onSave,
            icon: isSaving
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined, size: 18),
            label: Text(
              isCsvTab ? 'Salvar CSV' : (isDirty ? 'Salvar cópia' : 'Salvar'),
            ),
          ),
        ],
      ),
    );
  }
}

String _themeModeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.system => 'Seguir o sistema',
  ThemeMode.light => 'Claro',
  ThemeMode.dark => 'Escuro',
};

class _AliasEditDialog extends StatefulWidget {
  const _AliasEditDialog({required this.namespace, required this.alias});

  final String namespace;
  final String alias;

  @override
  State<_AliasEditDialog> createState() => _AliasEditDialogState();
}

class _AliasEditDialogState extends State<_AliasEditDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.alias);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Apelidar conjunto'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Apelido',
          hintText: 'Ex.: Personagens',
        ),
        onSubmitted: (value) =>
            Navigator.pop(context, _AliasDialogResult.save(value)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        if (widget.alias.isNotEmpty)
          TextButton(
            onPressed: () =>
                Navigator.pop(context, const _AliasDialogResult.remove()),
            child: const Text('Remover apelido'),
          ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, _AliasDialogResult.save(_controller.text)),
          child: const Text('Salvar apelido'),
        ),
      ],
    );
  }
}

class _ProjectNameDialog extends StatefulWidget {
  const _ProjectNameDialog({required this.defaultName});

  final String defaultName;

  @override
  State<_ProjectNameDialog> createState() => _ProjectNameDialogState();
}

class _ProjectNameDialogState extends State<_ProjectNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.defaultName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Identifique o projeto'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Nome do projeto'),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Abrir projeto'),
        ),
      ],
    );
  }
}

class _GroupExportDialog extends StatefulWidget {
  const _GroupExportDialog({
    required this.namespaces,
    required this.aliases,
    required this.entries,
  });

  final List<String> namespaces;
  final Map<String, String> aliases;
  final List<LocresEntry> entries;

  @override
  State<_GroupExportDialog> createState() => _GroupExportDialogState();
}

class _GroupExportDialogState extends State<_GroupExportDialog> {
  final Set<String> _selected = {};

  late final Map<String, int> _entryCounts;
  late final Map<String, int> _editedCounts;

  @override
  void initState() {
    super.initState();
    _entryCounts = {};
    _editedCounts = {};
    for (final entry in widget.entries) {
      _entryCounts.update(
        entry.namespace,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      if (entry.editedText != entry.originalText) {
        _editedCounts.update(
          entry.namespace,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final allSelected = _selected.length == widget.namespaces.length;
    return AlertDialog(
      title: const Text('Criar CSV para edição'),
      content: SizedBox(
        width: 560,
        height: 500,
        child: Column(
          children: [
            const Text(
              'Escolha os conjuntos que serão enviados. Chaves, originais e hashes identificam cada texto; células editadas vazias ficam sem alteração no merge.',
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() {
                  if (allSelected) {
                    _selected.clear();
                  } else {
                    _selected.addAll(widget.namespaces);
                  }
                }),
                child: Text(
                  allSelected ? 'Desmarcar todos' : 'Selecionar todos',
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: widget.namespaces.length,
                itemBuilder: (context, index) {
                  final namespace = widget.namespaces[index];
                  final alias = widget.aliases[namespace]?.trim() ?? '';
                  final name = alias.isEmpty
                      ? namespace
                      : '$alias ($namespace)';
                  return CheckboxListTile(
                    dense: true,
                    value: _selected.contains(namespace),
                    title: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${_editedCounts[namespace] ?? 0}/${_entryCounts[namespace]} editados',
                    ),
                    onChanged: (checked) => setState(() {
                      if (checked == true) {
                        _selected.add(namespace);
                      } else {
                        _selected.remove(namespace);
                      }
                    }),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(context, Set<String>.from(_selected)),
          child: const Text('Exportar conjuntos'),
        ),
      ],
    );
  }
}

class _WorkspaceTabs extends StatelessWidget {
  const _WorkspaceTabs({
    required this.tabs,
    required this.activeTab,
    required this.onSelect,
    required this.onClose,
  });

  final List<LocresWorkspaceTab> tabs;
  final LocresWorkspaceTab? activeTab;
  final ValueChanged<int> onSelect;
  final ValueChanged<LocresWorkspaceTab> onClose;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: tabs.isEmpty
          ? Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Nenhum Locres aberto',
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
            )
          : ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: tabs.length,
              separatorBuilder: (context, index) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                final tab = tabs[index];
                final isActive = identical(tab, activeTab);
                return Tooltip(
                  message: '${tab.projectName}\n${tab.path}',
                  child: Material(
                    color: isActive ? colors.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(9),
                      onTap: () => onSelect(index),
                      child: SizedBox(
                        width: 205,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 11, right: 4),
                          child: Row(
                            children: [
                              Icon(
                                Icons.description_outlined,
                                size: 17,
                                color: isActive
                                    ? colors.primary
                                    : colors.onSurfaceVariant,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      tab.projectName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: isActive
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                      ),
                                    ),
                                    Text(
                                      '${tab.fileName}${tab.hasUnsavedChanges ? ' • pendente' : ''}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: colors.onSurfaceVariant,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: 'Fechar Locres',
                                visualDensity: VisualDensity.compact,
                                onPressed: () => onClose(tab),
                                icon: const Icon(Icons.close_rounded, size: 16),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.document,
    required this.groups,
    required this.selectedNamespace,
    required this.aliases,
    required this.finalizedNamespaces,
    required this.searchController,
    required this.isOpening,
    required this.onSearchChanged,
    required this.onOpen,
    required this.onSelect,
    required this.onToggleFinalized,
    required this.onEditAlias,
    required this.onRemoveAlias,
  });

  final LocresDocument? document;
  final Map<String, _GroupProgress> groups;
  final String? selectedNamespace;
  final Map<String, String> aliases;
  final Set<String> finalizedNamespaces;
  final TextEditingController searchController;
  final bool isOpening;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onOpen;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onToggleFinalized;
  final ValueChanged<String> onEditAlias;
  final ValueChanged<String> onRemoveAlias;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final total = document?.entries.length ?? 0;
    final edited =
        document?.entries
            .where((entry) => entry.editedText != entry.originalText)
            .length ??
        0;

    return ColoredBox(
      color: colors.surfaceContainerLowest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 12),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'CONJUNTOS',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (document != null)
                  Text(
                    '$edited editados',
                    style: TextStyle(fontSize: 11, color: colors.primary),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: TextField(
              controller: searchController,
              onChanged: onSearchChanged,
              decoration: const InputDecoration(
                hintText: 'Buscar conjuntos',
                prefixIcon: Icon(Icons.search_rounded, size: 20),
                contentPadding: EdgeInsets.symmetric(vertical: 11),
              ),
            ),
          ),
          if (document != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_open_rounded,
                    size: 17,
                    color: colors.primary,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    '${groups.length} conjuntos',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    document!.versionLabel,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: groups.isEmpty
                  ? Center(
                      child: Text(
                        total == 0
                            ? 'Este arquivo não tem entradas.'
                            : 'Nenhum resultado.',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      itemCount: groups.length,
                      itemBuilder: (context, index) {
                        final namespace = groups.keys.elementAt(index);
                        final progress = groups[namespace]!;
                        final isSelected = namespace == selectedNamespace;
                        final isFinalized = finalizedNamespaces.contains(
                          namespace,
                        );
                        final originalName = namespace.isEmpty
                            ? '(sem conjunto)'
                            : namespace;
                        final alias = aliases[namespace]?.trim() ?? '';
                        final name = alias.isEmpty ? originalName : alias;
                        return GestureDetector(
                          onSecondaryTapDown: (details) {
                            _showGroupContextMenu(
                              context,
                              namespace,
                              details.globalPosition,
                              alias.isNotEmpty,
                              isFinalized,
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 3, 8, 3),
                            child: Material(
                              color: isSelected
                                  ? colors.secondaryContainer
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: () => onSelect(namespace),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 11,
                                    vertical: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.folder_outlined,
                                        size: 17,
                                        color: isSelected
                                            ? colors.primary
                                            : colors.outline,
                                      ),
                                      const SizedBox(width: 9),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              '${progress.edited}/${progress.total} editados',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: colors.onSurfaceVariant,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: isFinalized
                                            ? 'Reabrir conjunto'
                                            : 'Marcar conjunto como finalizado',
                                        visualDensity: VisualDensity.compact,
                                        onPressed: () =>
                                            onToggleFinalized(namespace),
                                        icon: Icon(
                                          isFinalized
                                              ? Icons.check_circle_rounded
                                              : Icons.radio_button_unchecked,
                                          color: isFinalized
                                              ? colors.primary
                                              : colors.outline,
                                          size: 19,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ] else ...[
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Icon(
                    Icons.folder_open_outlined,
                    size: 38,
                    color: colors.outline,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Abra um arquivo Locres para começar.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.tonalIcon(
                    onPressed: isOpening ? null : onOpen,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Abrir arquivo'),
                  ),
                ],
              ),
            ),
            const Spacer(),
          ],
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 11, 16, 13),
            child: Text(
              'Locres Hub • Edição local',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showGroupContextMenu(
    BuildContext context,
    String namespace,
    Offset globalPosition,
    bool hasAlias,
    bool isFinalized,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final localPosition = overlay.globalToLocal(globalPosition);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        localPosition.dx,
        localPosition.dy,
        overlay.size.width - localPosition.dx,
        overlay.size.height - localPosition.dy,
      ),
      items: [
        PopupMenuItem(
          value: isFinalized ? 'reopen' : 'finalize',
          child: ListTile(
            dense: true,
            leading: Icon(
              isFinalized
                  ? Icons.undo_rounded
                  : Icons.check_circle_outline_rounded,
            ),
            title: Text(
              isFinalized ? 'Reabrir conjunto' : 'Marcar como finalizado',
            ),
          ),
        ),
        const PopupMenuItem(
          value: 'edit',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.drive_file_rename_outline_rounded),
            title: Text('Editar apelido'),
          ),
        ),
        if (hasAlias)
          const PopupMenuItem(
            value: 'remove',
            child: ListTile(
              dense: true,
              leading: Icon(Icons.label_off_outlined),
              title: Text('Remover apelido'),
            ),
          ),
      ],
    );
    if (action == 'finalize' || action == 'reopen') {
      onToggleFinalized(namespace);
    }
    if (action == 'edit') onEditAlias(namespace);
    if (action == 'remove') onRemoveAlias(namespace);
  }
}

class _GroupEditor extends StatelessWidget {
  const _GroupEditor({
    required this.namespace,
    required this.version,
    required this.entries,
    required this.allEntries,
    required this.alias,
    required this.searchController,
    required this.onSearchChanged,
    required this.editFilter,
    required this.onEditFilterChanged,
    required this.onChanged,
  });

  final String namespace;
  final String version;
  final List<LocresEntry> entries;
  final List<LocresEntry> allEntries;
  final String? alias;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final _EditFilter editFilter;
  final ValueChanged<_EditFilter> onEditFilterChanged;
  final void Function(LocresEntry entry, String value) onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final editedCount = allEntries
        .where((entry) => entry.editedText != entry.originalText)
        .length;
    final originalName = namespace.isEmpty ? '(sem conjunto)' : namespace;
    final trimmedAlias = alias?.trim() ?? '';
    final groupName = trimmedAlias.isEmpty
        ? originalName
        : '$originalName ($trimmedAlias)';

    return LayoutBuilder(
      builder: (context, constraints) {
        final keyWidth = constraints.maxWidth < 720 ? 110.0 : 190.0;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.folder_open_rounded, color: colors.primary),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          groupName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${entries.length} de ${allEntries.length} textos • $editedCount editados • $version',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: searchController,
                onChanged: onSearchChanged,
                decoration: const InputDecoration(
                  hintText: 'Buscar somente nos textos deste conjunto',
                  prefixIcon: Icon(Icons.search_rounded, size: 19),
                  contentPadding: EdgeInsets.symmetric(vertical: 9),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 7,
                runSpacing: 2,
                children: [
                  _statusFilterChip(
                    label: 'Todos (${allEntries.length})',
                    filter: _EditFilter.all,
                  ),
                  _statusFilterChip(
                    label: 'Editados ($editedCount)',
                    filter: _EditFilter.edited,
                  ),
                  _statusFilterChip(
                    label: 'Não editados (${allEntries.length - editedCount})',
                    filter: _EditFilter.notEdited,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              _TranslationTableHeader(keyWidth: keyWidth),
              const Divider(height: 1),
              Expanded(
                child: entries.isEmpty
                    ? Center(
                        child: Text(
                          'Nenhum texto corresponde aos filtros atuais.',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      )
                    : FocusScope(
                        child: ListView.separated(
                          itemCount: entries.length,
                          separatorBuilder: (context, index) =>
                              const Divider(height: 1),
                          itemBuilder: (context, index) => _TranslationRow(
                            key: ValueKey(entries[index]),
                            entry: entries[index],
                            keyWidth: keyWidth,
                            onChanged: onChanged,
                          ),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _statusFilterChip({
    required String label,
    required _EditFilter filter,
  }) {
    return ChoiceChip(
      label: Text(label),
      selected: editFilter == filter,
      visualDensity: VisualDensity.compact,
      onSelected: (_) => onEditFilterChanged(filter),
    );
  }
}

class _TranslationTableHeader extends StatelessWidget {
  const _TranslationTableHeader({required this.keyWidth});

  final double keyWidth;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontSize: 10,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.5,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
      child: Row(
        children: [
          SizedBox(
            width: keyWidth,
            child: Text('OBJETO', style: style),
          ),
          Expanded(child: Text('ORIGINAL', style: style)),
          const SizedBox(width: 12),
          Expanded(child: Text('EDITADO', style: style)),
        ],
      ),
    );
  }
}

class _TranslationRow extends StatefulWidget {
  const _TranslationRow({
    super.key,
    required this.entry,
    required this.keyWidth,
    required this.onChanged,
  });

  final LocresEntry entry;
  final double keyWidth;
  final void Function(LocresEntry entry, String value) onChanged;

  @override
  State<_TranslationRow> createState() => _TranslationRowState();
}

class _TranslationRowState extends State<_TranslationRow> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.entry.editedText);
    _focusNode = FocusNode(onKeyEvent: _handleKeyEvent);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final scope = FocusScope.of(context);
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      scope.nextFocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      scope.previousFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void didUpdateWidget(covariant _TranslationRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.entry, widget.entry)) {
      _controller.text = widget.entry.editedText;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final entry = widget.entry;
    final originalStyle = TextStyle(color: colors.onSurface, fontSize: 12);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: widget.keyWidth,
            child: Tooltip(
              message: entry.key,
              child: Text(
                entry.key,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          Expanded(
            child: Tooltip(
              message: entry.originalText,
              child: Text(
                entry.originalText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: originalStyle,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              onChanged: (value) => widget.onChanged(entry, value),
              maxLines: 1,
              style: originalStyle,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Editar texto',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 9,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoGroupSelectionPanel extends StatelessWidget {
  const _NoGroupSelectionPanel({required this.hasEntries});

  final bool hasEntries;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        hasEntries
            ? 'Nenhum conjunto corresponde à busca da esquerda.'
            : 'Este arquivo não contém textos para exibir.',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _WelcomePanel extends StatelessWidget {
  const _WelcomePanel();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Icon(
                  Icons.translate_rounded,
                  size: 38,
                  color: colors.primary,
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                'Vamos editar um Locres?',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Text(
                'Abra um arquivo de localização da Unreal para pesquisar as entradas, editar os textos e salvar uma cópia.',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurfaceVariant, height: 1.5),
              ),
              const SizedBox(height: 24),
              const Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  _FeatureTag(icon: Icons.search_rounded, label: 'Buscar'),
                  _FeatureTag(icon: Icons.edit_rounded, label: 'Editar'),
                  _FeatureTag(icon: Icons.school_outlined, label: 'Aprender'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureTag extends StatelessWidget {
  const _FeatureTag({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Chip(
      avatar: Icon(icon, size: 15, color: colors.primary),
      label: Text(label),
      side: BorderSide.none,
      backgroundColor: colors.surfaceContainerHighest,
      visualDensity: VisualDensity.compact,
    );
  }
}

class _GuideStep extends StatelessWidget {
  const _GuideStep({
    required this.number,
    required this.title,
    required this.description,
  });

  final String number;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: colors.primaryContainer,
            foregroundColor: colors.primary,
            child: Text(number, style: const TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(description, style: const TextStyle(height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
