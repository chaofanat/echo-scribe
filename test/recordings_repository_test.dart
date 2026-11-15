import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:echo_scribe/library/recordings_repository.dart';

void main() {
  late Directory tmp;
  late RecordingsRepository repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('echoscribe_test_');
    repo = RecordingsRepository(tmp.path);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<void> writeRecording(
    String stem, {
    DateTime? createdAt,
    String transcript = '',
  }) async {
    await File('${tmp.path}/$stem.wav').writeAsBytes(List.filled(100, 0));
    final sidecar = File('${tmp.path}/$stem.json');
    await sidecar.writeAsString(
      '{"title": "$stem", "createdAt": "${(createdAt ?? DateTime(2026, 1, 1)).toIso8601String()}",'
      ' "durationMs": 5000, "transcript": "$transcript"}',
    );
  }

  test('list returns empty for missing directory', () async {
    expect(await RecordingsRepository('${tmp.path}/nope').list(), isEmpty);
  });

  test('list reads sidecars and sorts newest first', () async {
    await writeRecording('rec-old',
        createdAt: DateTime(2026, 1, 1), transcript: '旧的');
    await writeRecording('rec-new',
        createdAt: DateTime(2026, 1, 2), transcript: '新的');

    final items = await repo.list();
    expect(items.map((r) => r.id), ['rec-new', 'rec-old']);
    expect(items.first.transcript, '新的');
    expect(items.first.duration, const Duration(seconds: 5));
  });

  test('list tolerates wav without sidecar', () async {
    await File('${tmp.path}/rec-orphan.wav').writeAsBytes(List.filled(10, 0));

    final items = await repo.list();
    expect(items, hasLength(1));
    expect(items.first.id, 'rec-orphan');
    expect(items.first.title, 'rec-orphan');
    expect(items.first.transcript, isEmpty);
  });

  test('list tolerates corrupt sidecar json', () async {
    await File('${tmp.path}/rec-bad.wav').writeAsBytes(List.filled(10, 0));
    await File('${tmp.path}/rec-bad.json').writeAsString('{not json');

    final items = await repo.list();
    expect(items, hasLength(1));
    expect(items.first.id, 'rec-bad');
  });

  test('rename updates title and persists', () async {
    await writeRecording('rec-a', transcript: '你好');
    final item = (await repo.list()).single;

    await repo.rename(item, '会议记录');
    expect(item.title, '会议记录');

    final reloaded = (await repo.list()).single;
    expect(reloaded.title, '会议记录');
    expect(reloaded.transcript, '你好');
  });

  test('delete removes wav and sidecar', () async {
    await writeRecording('rec-a');
    final item = (await repo.list()).single;

    await repo.delete(item);

    expect(await repo.list(), isEmpty);
    expect(await File('${tmp.path}/rec-a.wav').exists(), isFalse);
    expect(await File('${tmp.path}/rec-a.json').exists(), isFalse);
  });
}
