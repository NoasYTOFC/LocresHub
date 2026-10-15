import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locres_hub/locres_codec.dart';
import 'package:locres_hub/main.dart';
import 'package:locres_hub/workspace_store.dart';

void main() {
  testWidgets('shows the workspace and its project tab', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: LocresHomePage(initialDocument: _emptyDocument())),
    );

    expect(find.text('Locres Hub'), findsOneWidget);
    expect(find.text('Exemplo'), findsOneWidget);
    expect(
      find.text('Este arquivo não contém textos para exibir.'),
      findsOneWidget,
    );
  });

  testWidgets('groups texts and filters edits separately from search', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: LocresHomePage(initialDocument: _sampleDocument())),
    );

    expect(find.text('ST_CharacterWords_Ch001'), findsNWidgets(2));
    expect(find.text('Cht_001'), findsOneWidget);
    expect(find.text('Original line one'), findsNWidgets(2));
    expect(find.text('0/2 editados'), findsOneWidget);
    expect(find.byTooltip('Marcar conjunto como finalizado'), findsNWidgets(2));

    await tester.tap(find.byTooltip('Marcar conjunto como finalizado').first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Reabrir conjunto'), findsOneWidget);
    expect(find.byTooltip('Marcar conjunto como finalizado'), findsOneWidget);

    var fields = find.byType(TextField);
    await tester.enterText(fields.at(2), 'Edited line one');
    await tester.pumpAndSettle();
    expect(find.text('Edited line one'), findsOneWidget);
    expect(find.text('1/2 editados'), findsOneWidget);

    await tester.tap(find.text('Editados (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Cht_001'), findsOneWidget);
    expect(find.text('Cht_002'), findsNothing);

    await tester.tap(find.text('Não editados (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Cht_001'), findsNothing);
    expect(find.text('Cht_002'), findsOneWidget);

    await tester.tap(find.text('Todos (2)'));
    await tester.pumpAndSettle();
    fields = find.byType(TextField);
    await tester.enterText(fields.at(1), 'Original line one');
    await tester.pumpAndSettle();
    expect(find.text('Cht_001'), findsOneWidget);
    expect(find.text('Cht_002'), findsNothing);
    expect(find.text('Inventory'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(1), 'no matching text');
    await tester.pumpAndSettle();
    expect(
      find.text('Nenhum texto corresponde aos filtros atuais.'),
      findsOneWidget,
    );
    expect(find.text('Inventory'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Inventory');
    await tester.pumpAndSettle();
    expect(find.text('ST_CharacterWords_Ch001'), findsNothing);
    expect(find.text('Inventory'), findsNWidgets(3));
    expect(find.text('Item_001'), findsOneWidget);
    expect(find.text('Potion'), findsNWidgets(2));
  });

  testWidgets('right-click aliases appear left and beside the original name', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: LocresHomePage(initialDocument: _sampleDocument())),
    );

    final group = find.text('ST_CharacterWords_Ch001').first;
    final gesture = await tester.startGesture(
      tester.getCenter(group),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Editar apelido'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Personagens');
    await tester.tap(find.text('Salvar apelido'));
    await tester.pumpAndSettle();

    expect(find.text('Personagens'), findsOneWidget);
    expect(find.text('ST_CharacterWords_Ch001 (Personagens)'), findsOneWidget);
    expect(find.text('ST_CharacterWords_Ch001'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'Personagens');
    await tester.pumpAndSettle();
    expect(find.text('Personagens'), findsNWidgets(2));
    expect(find.text('Inventory'), findsNothing);
  });

  testWidgets('up and down move focus between editable texts', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: LocresHomePage(initialDocument: _sampleDocument())),
    );
    final editors = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == 'Editar texto',
    );

    await tester.tap(editors.first);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.enterText(editors.last, 'Changed with arrow down');
    await tester.pump();
    expect(find.text('Changed with arrow down'), findsOneWidget);
    expect(
      tester.widget<TextField>(editors.first).controller!.text,
      'Original line one',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.enterText(editors.first, 'Changed with arrow up');
    await tester.pump();
    expect(find.text('Changed with arrow up'), findsOneWidget);
  });

  testWidgets('control plus a number selects the matching open tab', (
    tester,
  ) async {
    final tabs = [
      _workspaceTab('Projeto um', 'one.locres'),
      _workspaceTab('Projeto dois', 'two.locres'),
    ];
    await tester.pumpWidget(
      MaterialApp(home: LocresHomePage(initialTabs: tabs)),
    );
    expect(find.text('Projeto um — one.locres'), findsOneWidget);

    await tester.tap(find.text('Projeto um').first);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.digit2, character: '2');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.digit2);
    await tester.pumpAndSettle();

    expect(find.text('Projeto dois — two.locres'), findsOneWidget);
  });

  testWidgets('theme menu offers a dark theme and reports its selection', (
    tester,
  ) async {
    var themeMode = ThemeMode.light;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => MaterialApp(
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          themeMode: themeMode,
          home: LocresHomePage(
            initialDocument: _emptyDocument(),
            onThemeModeChanged: (mode) => setState(() => themeMode = mode),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Tema: Seguir o sistema'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Escuro'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(themeMode, ThemeMode.dark);
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).brightness,
      Brightness.dark,
    );
  });

  testWidgets('CSV menu opens CSVs alone, imports, or merges another Locres', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: LocresHomePage(initialDocument: _sampleDocument())),
    );

    await tester.tap(find.byTooltip('CSV e merge'));
    await tester.pumpAndSettle();

    expect(find.text('Importar CSVs na aba atual'), findsOneWidget);
    expect(find.text('Abrir CSV para edição...'), findsOneWidget);
    expect(find.text('Abrir projeto online...'), findsOneWidget);
    expect(find.text('Merge Locres + CSVs...'), findsOneWidget);
  });

  testWidgets('online project dialog explains setup and accepts a sheet link', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: LocresHomePage(initialDocument: _sampleDocument())),
    );

    await tester.tap(find.byTooltip('CSV e merge'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Abrir projeto online...'));
    await tester.pumpAndSettle();

    expect(find.text('Conectar projeto online'), findsOneWidget);
    expect(find.text('Prepare a planilha'), findsOneWidget);
    expect(find.text('Compartilhe com a equipe'), findsOneWidget);
    expect(find.text('Conecte e sincronize'), findsOneWidget);
    expect(find.text('Link da planilha Google'), findsOneWidget);
    expect(find.text('Conectar'), findsOneWidget);
  });

  testWidgets('a CSV tab displays editable rows without a Locres tab', (
    tester,
  ) async {
    final csvTab = LocresWorkspaceTab(
      path: 'parte.csv',
      projectName: 'Parte da equipe',
      document: _sampleDocument(),
      aliases: {},
      sourceType: WorkspaceSourceType.csv,
    );
    await tester.pumpWidget(
      MaterialApp(home: LocresHomePage(initialTabs: [csvTab])),
    );

    expect(find.text('Parte da equipe — parte.csv'), findsOneWidget);
    expect(find.text('Original line one'), findsNWidgets(2));
    expect(find.text('Salvar CSV'), findsOneWidget);
  });
}

LocresDocument _emptyDocument() => LocresDocument(
  originalBytes: Uint8List(0),
  version: 0,
  poolOffset: null,
  poolEnd: null,
  pool: [],
  entries: [],
);

LocresDocument _sampleDocument() => LocresDocument(
  originalBytes: Uint8List(0),
  version: 0,
  poolOffset: null,
  poolEnd: null,
  pool: [],
  entries: [
    LocresEntry(
      namespace: 'ST_CharacterWords_Ch001',
      key: 'Cht_001',
      originalText: 'Original line one',
      sourceStringHash: 1,
      wasUtf16: false,
      textOffset: 0,
    ),
    LocresEntry(
      namespace: 'ST_CharacterWords_Ch001',
      key: 'Cht_002',
      originalText: 'Original line two',
      sourceStringHash: 2,
      wasUtf16: false,
      textOffset: 0,
    ),
    LocresEntry(
      namespace: 'Inventory',
      key: 'Item_001',
      originalText: 'Potion',
      sourceStringHash: 3,
      wasUtf16: false,
      textOffset: 0,
    ),
  ],
);

LocresWorkspaceTab _workspaceTab(String projectName, String path) =>
    LocresWorkspaceTab(
      path: path,
      projectName: projectName,
      document: _emptyDocument(),
      aliases: {},
    );
