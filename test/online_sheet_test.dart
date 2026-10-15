import 'package:flutter_test/flutter_test.dart';
import 'package:locres_hub/online_sheet.dart';

void main() {
  group('OnlineSheet.parseUrl', () {
    test('accepts a standard shared Google Sheets link', () {
      final uri = OnlineSheet.parseUrl(
        'https://docs.google.com/spreadsheets/d/spreadsheet-id/edit?gid=0',
      );

      expect(uri.host, 'docs.google.com');
      expect(uri.pathSegments, contains('spreadsheet-id'));
    });

    test('accepts links with a user path before the spreadsheet id', () {
      final uri = OnlineSheet.parseUrl(
        'https://docs.google.com/spreadsheets/u/0/d/spreadsheet-id/edit',
      );

      expect(uri.pathSegments, contains('spreadsheet-id'));
    });

    test('rejects non-Google links', () {
      expect(
        () => OnlineSheet.parseUrl('https://example.com/spreadsheets/d/id'),
        throwsA(isA<OnlineSheetException>()),
      );
    });

    test('rejects Google URLs without a spreadsheet id', () {
      expect(
        () => OnlineSheet.parseUrl('https://docs.google.com/spreadsheets/'),
        throwsA(isA<OnlineSheetException>()),
      );
    });
  });
}
