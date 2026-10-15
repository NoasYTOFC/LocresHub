import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:googleapis_auth/auth_io.dart' as google_auth;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'locres_codec.dart';
import 'workspace_store.dart';

class OnlineSyncResult {
  const OnlineSyncResult({
    required this.sent,
    required this.conflicts,
    required this.missing,
    required this.added,
  });

  final int sent;
  final int conflicts;
  final int missing;
  final int added;
}

class OnlineSheetException implements Exception {
  const OnlineSheetException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _SheetRow {
  const _SheetRow({
    required this.id,
    required this.rowNumber,
    required this.namespace,
    required this.key,
    required this.original,
    required this.edited,
    required this.hash,
  });

  final String id;
  final int rowNumber;
  final String namespace;
  final String key;
  final String original;
  final String edited;
  final int hash;
}

class _SheetSnapshot {
  const _SheetSnapshot({
    required this.projectName,
    required this.sheetName,
    required this.editedColumn,
    required this.rows,
  });

  final String projectName;
  final String sheetName;
  final int editedColumn;
  final List<_SheetRow> rows;
}

class OnlineSheet {
  static const _clientId = String.fromEnvironment('GOOGLE_OAUTH_CLIENT_ID');
  static const _clientSecret = String.fromEnvironment(
    'GOOGLE_OAUTH_CLIENT_SECRET',
  );
  static const _scope = 'https://www.googleapis.com/auth/spreadsheets';
  static const _timeout = Duration(seconds: 60);
  static const _headers = [
    'namespace',
    'key',
    'original',
    'edited',
    'sourceStringHash',
  ];

  static http.Client? _authorizedClient;
  static Future<http.Client>? _authorizationInProgress;

  static String entryId(String namespace, String key, int hash) =>
      '$namespace\u0001$key\u0001$hash';

  static Uri parseUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.scheme != 'https' || uri.host != 'docs.google.com') {
      throw const OnlineSheetException(
        'Cole o link da planilha do Google Planilhas.',
      );
    }
    final segments = uri.pathSegments;
    final markerIndex = segments.indexOf('d');
    if (markerIndex < 0 || markerIndex + 1 >= segments.length) {
      throw const OnlineSheetException(
        'O link não contém o identificador esperado da planilha.',
      );
    }
    return uri;
  }

  static Future<LocresWorkspaceTab> open(Uri url) async {
    final spreadsheetId = _spreadsheetId(url);
    final snapshot = await _readSheet(spreadsheetId);
    final tab = LocresWorkspaceTab(
      path: url.toString(),
      projectName: snapshot.projectName,
      document: LocresDocument(
        originalBytes: Uint8List(0),
        version: 0,
        poolOffset: null,
        poolEnd: null,
        pool: [],
        entries: [],
      ),
      aliases: {},
      sourceType: WorkspaceSourceType.online,
    );
    _merge(tab, snapshot.rows, const {});
    _markSynced(tab);
    return tab;
  }

  static Future<OnlineSyncResult> sync(LocresWorkspaceTab tab) async {
    final spreadsheetId = _spreadsheetId(Uri.parse(tab.path));
    final before = await _readSheet(spreadsheetId);
    final remoteById = {for (final row in before.rows) row.id: row};
    final snapshot = <String, String>{};
    final updates = <Map<String, Object?>>[];
    var conflicts = 0;
    var missing = 0;

    for (final entry in tab.document.entries) {
      final id = entryId(entry.namespace, entry.key, entry.sourceStringHash);
      final edited = _effective(entry);
      snapshot[id] = edited;
      final base = tab.remoteBase[id] ?? '';
      if (edited == base) continue;

      final remoteRow = remoteById[id];
      if (remoteRow == null) {
        missing++;
        continue;
      }
      if (remoteRow.edited == edited) continue;
      if (remoteRow.edited != base) {
        conflicts++;
        continue;
      }
      updates.add({
        'range':
            "'${before.sheetName.replaceAll("'", "''")}'!"
            '${_columnName(before.editedColumn)}${remoteRow.rowNumber}',
        'values': [
          [edited],
        ],
      });
    }

    if (updates.isNotEmpty) {
      await _request(
        'POST',
        'https://sheets.googleapis.com/v4/spreadsheets/'
            '${Uri.encodeComponent(spreadsheetId)}/values:batchUpdate',
        {'valueInputOption': 'RAW', 'data': updates},
      );
    }

    final after = await _readSheet(spreadsheetId);
    final entriesBeforeMerge = tab.document.entries.length;
    _merge(tab, after.rows, snapshot);
    _markSynced(tab);
    return OnlineSyncResult(
      sent: updates.length,
      conflicts: conflicts,
      missing: missing,
      added: tab.document.entries.length - entriesBeforeMerge,
    );
  }

  static String _spreadsheetId(Uri url) {
    final segments = url.pathSegments;
    final markerIndex = segments.indexOf('d');
    if (markerIndex < 0 || markerIndex + 1 >= segments.length) {
      throw const OnlineSheetException(
        'O link não contém o identificador esperado da planilha.',
      );
    }
    return segments[markerIndex + 1];
  }

  static Future<_SheetSnapshot> _readSheet(String spreadsheetId) async {
    final metadata = await _request(
      'GET',
      'https://sheets.googleapis.com/v4/spreadsheets/'
          '${Uri.encodeComponent(spreadsheetId)}'
          '?fields=properties.title,sheets.properties.title',
    );
    final properties = metadata['properties'];
    final sheets = metadata['sheets'];
    if (properties is! Map ||
        sheets is! List ||
        sheets.isEmpty ||
        sheets.first is! Map) {
      throw const OnlineSheetException(
        'A planilha não tem uma primeira aba legível.',
      );
    }
    final projectName = '${properties['title'] ?? ''}'.trim();
    final sheetProperties = sheets.first['properties'];
    if (sheetProperties is! Map) {
      throw const OnlineSheetException(
        'Não foi possível identificar a primeira aba da planilha.',
      );
    }
    final sheetName = '${sheetProperties['title'] ?? ''}';
    if (sheetName.isEmpty) {
      throw const OnlineSheetException(
        'A primeira aba da planilha está sem nome.',
      );
    }
    final range = Uri.encodeComponent(
      "'${sheetName.replaceAll("'", "''")}'!A:E",
    );
    final values = await _request(
      'GET',
      'https://sheets.googleapis.com/v4/spreadsheets/'
          '${Uri.encodeComponent(spreadsheetId)}/values/$range',
    );
    final rawRows = values['values'];
    if (rawRows is! List || rawRows.isEmpty || rawRows.first is! List) {
      throw const OnlineSheetException(
        'A planilha está vazia. Importe primeiro o CSV exportado pelo LocresHub.',
      );
    }

    final header = (rawRows.first as List).map((cell) => '$cell').toList();
    final columns = <String, int>{
      for (var i = 0; i < header.length; i++) header[i]: i,
    };
    if (_headers.any((name) => !columns.containsKey(name))) {
      throw OnlineSheetException(
        'A primeira linha precisa conter as colunas: ${_headers.join(', ')}.',
      );
    }

    String cell(List row, String name) {
      final index = columns[name]!;
      return index >= row.length ? '' : '${row[index]}';
    }

    final rows = <_SheetRow>[];
    final seen = <String>{};
    for (var index = 1; index < rawRows.length; index++) {
      final rawRow = rawRows[index];
      if (rawRow is! List) continue;
      final namespace = cell(rawRow, 'namespace');
      final key = cell(rawRow, 'key');
      final original = cell(rawRow, 'original');
      final editedValue = cell(rawRow, 'edited');
      final edited = editedValue == original ? '' : editedValue;
      final hash = _parseHash(cell(rawRow, 'sourceStringHash'));
      if (namespace.isEmpty &&
          key.isEmpty &&
          original.isEmpty &&
          edited.isEmpty &&
          hash == null) {
        continue;
      }
      if (hash == null) {
        throw OnlineSheetException(
          'O hash na linha ${index + 1} não é um número válido.',
        );
      }
      final id = entryId(namespace, key, hash);
      if (!seen.add(id)) {
        throw OnlineSheetException(
          'A chave "$namespace::$key" aparece mais de uma vez na planilha.',
        );
      }
      rows.add(
        _SheetRow(
          id: id,
          rowNumber: index + 1,
          namespace: namespace,
          key: key,
          original: original,
          edited: edited,
          hash: hash,
        ),
      );
    }
    return _SheetSnapshot(
      projectName: projectName.isEmpty ? 'Planilha online' : projectName,
      sheetName: sheetName,
      editedColumn: columns['edited']! + 1,
      rows: rows,
    );
  }

  static String _columnName(int column) {
    var value = column;
    var name = '';
    while (value > 0) {
      final remainder = (value - 1) % 26;
      name = String.fromCharCode(65 + remainder) + name;
      value = (value - 1) ~/ 26;
    }
    return name;
  }

  static int? _parseHash(String value) {
    final integer = int.tryParse(value);
    if (integer != null) return integer;
    final number = num.tryParse(value);
    if (number == null || number != number.roundToDouble()) return null;
    return number.toInt();
  }

  static void _merge(
    LocresWorkspaceTab tab,
    List<_SheetRow> rows,
    Map<String, String> snapshot,
  ) {
    final byId = {
      for (final entry in tab.document.entries)
        entryId(entry.namespace, entry.key, entry.sourceStringHash): entry,
    };
    final remoteBase = <String, String>{};
    for (final row in rows) {
      remoteBase[row.id] = row.edited;
      final existing = byId[row.id];
      if (existing == null) {
        final entry = LocresEntry(
          namespace: row.namespace,
          key: row.key,
          originalText: row.original,
          sourceStringHash: row.hash,
          wasUtf16: false,
          textOffset: tab.document.entries.length,
        );
        if (row.edited.isNotEmpty) entry.editedText = row.edited;
        tab.document.entries.add(entry);
        byId[row.id] = entry;
        continue;
      }
      final changedWhileSyncing =
          snapshot.containsKey(row.id) &&
          snapshot[row.id] != _effective(existing);
      if (changedWhileSyncing) continue;
      existing.editedText = row.edited.isEmpty
          ? existing.originalText
          : row.edited;
    }
    tab.remoteBase = remoteBase;
  }

  static void _markSynced(LocresWorkspaceTab tab) {
    final savedEdits = <int, String>{};
    for (var index = 0; index < tab.document.entries.length; index++) {
      final entry = tab.document.entries[index];
      final edited = _effective(entry);
      final id = entryId(entry.namespace, entry.key, entry.sourceStringHash);
      if (edited.isNotEmpty && edited == tab.remoteBase[id]) {
        savedEdits[index] = entry.editedText;
      }
    }
    tab.savedEdits = savedEdits;
  }

  static String _effective(LocresEntry entry) =>
      entry.editedText == entry.originalText ? '' : entry.editedText;

  static Future<http.Client> _client() async {
    final existing = _authorizedClient;
    if (existing != null) return existing;
    final inProgress = _authorizationInProgress;
    if (inProgress != null) return inProgress;

    if (_clientId.isEmpty || _clientSecret.isEmpty) {
      throw const OnlineSheetException(
        'O login Google ainda não foi configurado nesta versão do app. '
        'Compile com GOOGLE_OAUTH_CLIENT_ID e GOOGLE_OAUTH_CLIENT_SECRET.',
      );
    }

    final launchResult = Completer<void>();
    final authorization = google_auth.clientViaUserConsent(
      google_auth.ClientId(_clientId, _clientSecret),
      const [_scope],
      (authorizationUrl) {
        unawaited(() async {
          try {
            final launched = await launchUrl(
              Uri.parse(authorizationUrl),
              mode: LaunchMode.externalApplication,
            );
            if (!launched) {
              throw const OnlineSheetException(
                'Não foi possível abrir o navegador para entrar no Google.',
              );
            }
            if (!launchResult.isCompleted) launchResult.complete();
          } on Object catch (error, stackTrace) {
            if (!launchResult.isCompleted) {
              launchResult.completeError(
                OnlineSheetException('Falha ao abrir o login Google: $error'),
                stackTrace,
              );
            }
          }
        }());
      },
      customPostAuthPage:
          '<html><body><h2>Login concluído</h2>'
          '<p>Volte para o LocresHub. Você pode fechar esta página.</p></body></html>',
    );
    final result = Future.any<http.Client>([
      authorization,
      launchResult.future.then((_) => authorization),
    ]).timeout(const Duration(minutes: 3));
    _authorizationInProgress = result;
    try {
      final client = await result;
      _authorizedClient = client;
      return client;
    } on TimeoutException {
      throw const OnlineSheetException(
        'O login expirou. Tente entrar novamente.',
      );
    } on google_auth.UserConsentException catch (error) {
      throw OnlineSheetException('O login Google falhou: $error');
    } on google_auth.AccessDeniedException catch (error) {
      throw OnlineSheetException('O Google negou o acesso: $error');
    } on google_auth.AuthorizationCallbackException catch (error) {
      throw OnlineSheetException('O retorno do login Google falhou: $error');
    } on google_auth.ServerRequestFailedException catch (error) {
      throw OnlineSheetException('O login Google falhou: $error');
    } finally {
      _authorizationInProgress = null;
    }
  }

  static Future<Map<String, Object?>> _request(
    String method,
    String url, [
    Object? body,
  ]) async {
    final client = await _client();
    final uri = Uri.parse(url);
    late final http.Response response;
    try {
      response = await switch (method) {
        'GET' => client.get(uri).timeout(_timeout),
        'POST' =>
          client
              .post(
                uri,
                headers: const {
                  'content-type': 'application/json; charset=utf-8',
                },
                body: jsonEncode(body),
              )
              .timeout(_timeout),
        _ => throw StateError('Método HTTP não suportado: $method'),
      };
    } on SocketException catch (error) {
      throw OnlineSheetException('Sem conexão com o Google: ${error.message}');
    } on http.ClientException catch (error) {
      throw OnlineSheetException('Falha na conexão com o Google: $error');
    } on TimeoutException {
      throw const OnlineSheetException(
        'O Google demorou demais para responder. Tente novamente.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OnlineSheetException(_apiError(response.statusCode, response.body));
    }
    if (response.body.isEmpty) return {};
    late final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const OnlineSheetException(
        'O Google retornou uma resposta que não é JSON válido.',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const OnlineSheetException(
        'O Google retornou uma resposta inesperada.',
      );
    }
    return decoded;
  }

  static String _apiError(int statusCode, String body) {
    var message = '';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map) message = '${error['message'] ?? ''}';
      }
    } on FormatException {
      message = '';
    }
    if (statusCode == 403) {
      return message.isEmpty
          ? 'O Google negou o acesso. Confirme que sua conta tem permissão de edição na planilha.'
          : 'O Google negou o acesso: $message';
    }
    if (statusCode == 404) {
      return 'Planilha não encontrada ou sem permissão para acessá-la.';
    }
    return message.isEmpty
        ? 'Erro da API do Google ($statusCode).'
        : 'Erro da API do Google ($statusCode): $message';
  }
}
