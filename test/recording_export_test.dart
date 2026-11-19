import 'package:echo_scribe/library/recording_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('safeFileName strips Windows-forbidden characters', () {
    expect(safeFileName('会议/记录: "11月"'), '会议_记录_ _11月_');
    expect(safeFileName('plain title'), 'plain title');
  });

  test('safeFileName falls back when nothing usable remains', () {
    expect(safeFileName('   '), 'recording');
    expect(safeFileName(''), 'recording');
    // Slash-only input still yields a valid (if ugly) name.
    expect(safeFileName('///'), '___');
  });
}
