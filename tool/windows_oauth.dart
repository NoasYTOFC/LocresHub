import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final build = arguments.length == 1 && arguments.single == '--build';
  if (arguments.isNotEmpty && !build) {
    stderr.writeln('Uso: dart run tool/windows_oauth.dart [--build]');
    exitCode = 64;
    return;
  }

  final projectRoot = File.fromUri(Platform.script).parent.parent.path;
  final credentialFiles = Directory(projectRoot)
      .listSync()
      .whereType<File>()
      .where(
        (file) =>
            file.uri.pathSegments.last.startsWith('client_secret_') &&
            file.path.toLowerCase().endsWith('.json'),
      )
      .toList();

  if (credentialFiles.length != 1) {
    stderr.writeln(
      'Esperava exatamente um arquivo client_secret_*.json na raiz do projeto; '
      'encontrei ${credentialFiles.length}.',
    );
    exitCode = 1;
    return;
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(await credentialFiles.single.readAsString());
  } on FormatException {
    stderr.writeln('O arquivo de credenciais não contém JSON válido.');
    exitCode = 1;
    return;
  } on FileSystemException catch (error) {
    stderr.writeln(
      'Não foi possível ler o arquivo de credenciais: ${error.message}',
    );
    exitCode = 1;
    return;
  }

  if (decoded is! Map<String, dynamic>) {
    stderr.writeln('O JSON de credenciais tem um formato inválido.');
    exitCode = 1;
    return;
  }
  final installed = decoded['installed'];
  if (installed is! Map<String, dynamic> ||
      installed['client_id'] is! String ||
      installed['client_secret'] is! String ||
      (installed['client_id'] as String).isEmpty ||
      (installed['client_secret'] as String).isEmpty) {
    stderr.writeln(
      'O JSON precisa conter uma credencial OAuth do tipo Desktop app '
      '(objeto "installed").',
    );
    exitCode = 1;
    return;
  }

  final oauthDefines = [
    '--dart-define=GOOGLE_OAUTH_CLIENT_ID=${installed['client_id']}',
    '--dart-define=GOOGLE_OAUTH_CLIENT_SECRET=${installed['client_secret']}',
  ];
  final flutterArguments = build
      ? ['build', 'windows', ...oauthDefines]
      : ['run', '-d', 'windows', ...oauthDefines];

  final Process process;
  try {
    process = await Process.start(
      'flutter',
      flutterArguments,
      workingDirectory: projectRoot,
      mode: ProcessStartMode.inheritStdio,
      runInShell: true,
    );
  } on ProcessException catch (error) {
    stderr.writeln('Não foi possível iniciar Flutter: ${error.message}');
    exitCode = 1;
    return;
  }
  exitCode = await process.exitCode;
}
