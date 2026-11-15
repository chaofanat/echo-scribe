import 'package:flutter_test/flutter_test.dart';
import 'package:echo_scribe/library/recording_filter.dart';
import 'package:echo_scribe/library/recordings_repository.dart';

Recording _rec(
  String title, {
  String transcript = '',
  List<String> tags = const [],
}) {
  return Recording(
    wavPath: '/tmp/$title.wav',
    title: title,
    createdAt: DateTime(2026, 1, 1),
    duration: const Duration(seconds: 10),
    transcript: transcript,
    tags: tags,
  );
}

void main() {
  test('matchesQuery is case-insensitive over title and transcript', () {
    final rec = _rec('周会', transcript: 'Hello world 大家好');
    expect(matchesQuery(rec, ''), isTrue);
    expect(matchesQuery(rec, '  '), isTrue);
    expect(matchesQuery(rec, '周会'), isTrue);
    expect(matchesQuery(rec, 'hello WORLD'), isTrue);
    expect(matchesQuery(rec, '大家好'), isTrue);
    expect(matchesQuery(rec, '季度汇报'), isFalse);
  });

  test('collectTags orders by usage count then A-Z', () {
    final recordings = [
      _rec('a', tags: ['会议', '重要']),
      _rec('b', tags: ['会议']),
      _rec('c', tags: ['会议', '草稿']),
    ];
    // '会议' ×3 first; the single-use tags tie and order by code point.
    expect(collectTags(recordings), ['会议', '草稿', '重要']);
    expect(collectTags([]), isEmpty);
  });

  test('filterRecordings combines query and tag filters', () {
    final recordings = [
      _rec('周会', transcript: '项目进展', tags: ['会议']),
      _rec('访谈', transcript: '用户调研', tags: ['会议', '草稿']),
      _rec('笔记', transcript: '项目复盘', tags: ['草稿']),
    ];

    expect(filterRecordings(recordings), hasLength(3));
    expect(
      filterRecordings(recordings, query: '项目').map((r) => r.title),
      ['周会', '笔记'],
    );
    expect(
      filterRecordings(recordings, tag: '会议').map((r) => r.title),
      ['周会', '访谈'],
    );
    expect(
      filterRecordings(recordings, query: '用户', tag: '会议')
          .map((r) => r.title),
      ['访谈'],
    );
    expect(filterRecordings(recordings, query: '不存在的词'), isEmpty);
  });
}
