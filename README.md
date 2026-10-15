# Locres Hub

Editor didático para abrir, pesquisar e editar arquivos `.locres` de localização
da Unreal Engine. A primeira versão tem foco no desktop Windows e interface em
português.

## Recursos

- Abre arquivos Locres Legacy, Compact, Optimized e CityHash64 UTF-16.
- Agrupa entradas por conjunto (namespace, antes de `::`), como
  `ST_CharacterWords_Ch001::Cht_001`.
- Ao selecionar um conjunto, mostra seus textos em linhas compactas com o
  original ao lado do campo editável.
- Campo de pesquisa à esquerda filtra somente conjuntos; campo à direita filtra
  somente os textos do conjunto selecionado.
- Filtros para mostrar todos, apenas os editados ou apenas os não editados.
- A lista de conjuntos mostra quantos textos estão editados em cada um
  (`editados/total`) e permite marcar ou reabrir conjuntos como finalizados.
  Essa marcação é preservada junto ao arquivo Locres, inclusive ao fechar a aba.
- Clique com o botão direito em um conjunto para salvar ou remover um apelido.
  O apelido aparece no lado esquerdo e entre parênteses junto ao nome original
  no cabeçalho à direita.
- Mantém até cinco arquivos em abas separadas, cada uma identificada por um nome
  de projeto escolhido ao abrir o Locres.
- Alterna entre tema claro, escuro ou o tema do sistema pelo botão de tema no
  topo; a preferência é salva localmente.
- Atalhos de teclado: ↑/↓ nos campos editáveis percorrem os textos visíveis do
  conjunto; Ctrl+1 a Ctrl+5 seleciona a aba aberta correspondente.
- No menu **CSV e merge**, exporta apenas os textos alterados ou cria uma
  planilha de edição com os conjuntos selecionados. O CSV usa as colunas
  `namespace`, `key`, `original`, `edited` e `sourceStringHash`; as células
  `edited` vazias são tratadas como “não alterar”.
- Importa um ou mais CSVs diretamente para a aba Locres ativa, ou permite
  escolher outro Locres na opção **Merge Locres + CSVs**.
- Também abre CSVs como abas independentes, sem exigir um Locres. Assim, uma
  pessoa pode receber apenas o CSV de um conjunto, editá-lo e salvar uma cópia
  CSV para devolver à equipe.
- Conecta diretamente a planilhas Google pelo login OAuth de cada integrante.
  A conta precisa ter permissão de edição na planilha; as alterações são
  enviadas apenas para as células `edited` modificadas e a planilha é lida
  novamente após a sincronização. Edições simultâneas na mesma célula podem
  conflitar; o app verifica o valor remoto antes de gravar, mas a API do Sheets
  não fornece uma gravação condicional atômica.
- Mescla um Locres com vários CSVs: linhas vazias e chaves/hashes que não
  correspondem são ignorados; valores conflitantes entre planilhas são
  apresentados para escolha. O resultado fica como edição pendente na aba e
  pode ser salvo como uma cópia sem substituir o Locres de origem.
- Restaura localmente abas, apelidos e edições pendentes ao iniciar novamente.
  Uma aba permanece aberta até ser fechada manualmente; alterações pendentes
  podem ser salvas antes do fechamento. Apelidos e nomes de projeto permanecem
  salvos mesmo depois de fechar uma aba manualmente.
- Salva uma cópia `-editado.locres` sem substituir o arquivo original.
- Preserva as chaves e os hashes de texto-fonte ao editar os valores.
- Inclui um guia integrado explicando o fluxo básico de edição.

O texto exibido como referência é o valor localizado que já está no `.locres`;
esse arquivo não contém necessariamente o texto do idioma-fonte. Sempre teste a
cópia no projeto Unreal antes de usá-la em uma build.

## Executar no Windows

Instale o Flutter com suporte a desktop Windows e o Visual Studio com a carga de
trabalho **Desenvolvimento para desktop com C++**. Na raiz do projeto:

```powershell
flutter pub get
flutter run -d windows
```

O comando acima executa os recursos locais. Para executar com a integração
online, deixe o JSON OAuth de aplicativo desktop na raiz do projeto (o arquivo
`client_secret_*.json` é ignorado pelo Git) e use:

```powershell
dart run tool\windows_oauth.dart
```

Para gerar a versão compilada com o mesmo login:

```powershell
.\build_windows_oauth.bat
```

O login de planilhas requer um projeto no Google Cloud com a Google Sheets API
ativada e uma credencial OAuth do tipo **Aplicativo para computador**. Configure
a tela de consentimento OAuth para os integrantes que usarão o app. Os valores
do client ID e do client secret são lidos localmente pelo script; credenciais
de aplicativos desktop são públicas e não devem ser tratadas como segredos. Para
desenvolvimento, use o fluxo de configuração descrito em
[OAuth para aplicativos instalados](https://developers.google.com/identity/protocols/oauth2/native-app)
e habilite a [Google Sheets API](https://console.cloud.google.com/apis/library/sheets.googleapis.com).
Cada integrante entra na conta Google que recebeu acesso à planilha. O Google
aplica as permissões dessa conta e rejeita gravações de quem tiver apenas leitura.
A integração solicita o escopo de planilhas do Google; a publicação do app pode
exigir verificação OAuth do Google.

No menu **CSV e merge > Abrir projeto online**, cole o link padrão da planilha
(`https://docs.google.com/spreadsheets/d/...`). Importe primeiro o CSV exportado
pelo LocresHub na primeira aba da planilha sem alterar os cabeçalhos. Use
**Sincronizar** para enviar as edições e receber a versão atualizada. A
autorização fica apenas em memória durante a execução; ao reiniciar o app, entre
novamente na conta Google.

## Testes

```powershell
flutter test
flutter analyze
```
