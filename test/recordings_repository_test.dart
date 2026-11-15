import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:echo_scribe/asr/capture_source.dart';
import 'package:echo_scribe/asr/transcript_segment.dart';
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

  test('list reads speaker-labeled segments', () async {
    await writeRecording('rec-talk', transcript: '你好再见');
    await File('${tmp.path}/rec-talk.json').writeAsString(
      '{"title": "rec-talk", "createdAt": "${DateTime(2026, 1, 1).toIso8601String()}",'
      ' "durationMs": 8000, "transcript": "你好再见", "speakerCount": 2,'
      ' "segments": ['
      '{"text": "你好", "start": 0.0, "end": 2.5, "speaker": 0},'
      '{"text": "再见", "start": 2.5, "end": 4.0, "speaker": 1}]}',
    );

    final item = (await repo.list()).single;
    expect(item.speakerCount, 2);
    expect(item.segments, hasLength(2));
    expect(item.segments.first.speaker, 0);
    expect(item.segments.last.endSec, 4.0);
    expect(item.displayTranscript, '说话人1：你好\n说话人2：再见');
  });

  test('sidecars without segments fall back to plain transcript', () async {
    await writeRecording('rec-legacy', transcript: '旧录音');
    final item = (await repo.list()).single;

    expect(item.segments, isEmpty);
    expect(item.speakerCount, 0);
    expect(item.displayTranscript, '旧录音');
  });

  test('capture source round-trips through the sidecar', () async {
    await writeRecording('rec-loopback', transcript: '视频讲解');
    await File('${tmp.path}/rec-loopback.json').writeAsString(
      '{"title": "rec-loopback", "createdAt": "${DateTime(2026, 1, 1).toIso8601String()}",'
      ' "durationMs": 5000, "transcript": "视频讲解", "source": "system"}',
    );
    await writeRecording('rec-mic', transcript: '你好');

    final items = await repo.list();
    final loopback = items.firstWhere((r) => r.title == 'rec-loopback');
    expect(loopback.source, AudioSource.systemAudio);
    expect(loopback.toJson()['source'], 'system');

    // Older sidecars (and fresh mic recordings) read as microphone.
    final mic = items.firstWhere((r) => r.title == 'rec-mic');
    expect(mic.source, AudioSource.microphone);
    expect(mic.toJson()['source'], 'mic');
  });

  test('rename preserves segments through sidecar rewrite', () async {
    await writeRecording('rec-talk', transcript: '你好');
    await File('${tmp.path}/rec-talk.json').writeAsString(
      '{"title": "rec-talk", "createdAt": "${DateTime(2026, 1, 1).toIso8601String()}",'
      ' "durationMs": 5000, "transcript": "你好", "speakerCount": 1,'
      ' "segments": [{"text": "你好", "start": 0.0, "end": 1.5, "speaker": 0}]}',
    );
    final item = (await repo.list()).single;

    await repo.rename(item, '周会');
    final reloaded = (await repo.list()).single;

    expect(reloaded.title, '周会');
    expect(reloaded.speakerCount, 1);
    expect(reloaded.segments.single.text, '你好');
  });

  test('updateSegments rewrites attribution and keeps other metadata',
      () async {
    await writeRecording('rec-fix', transcript: '你好再见');
    final item = (await repo.list()).single;

    final segments = [
      TranscriptSegment(text: '你好', startSec: 0, endSec: 2)..speaker = 0,
      TranscriptSegment(text: '再见', startSec: 2.1, endSec: 4)..speaker = 1,
    ];
    await repo.updateSegments(
      item,
      segments,
      2,
      [
        {'start': 0.0, 'end': 2.0, 'speaker': 0},
        {'start': 2.1, 'end': 4.0, 'speaker': 1},
      ],
    );

    final reloaded = (await repo.list()).single;
    expect(reloaded.title, 'rec-fix');
    expect(reloaded.speakerCount, 2);
    expect(reloaded.segments.last.speaker, 1);
    expect(reloaded.displayTranscript, '说话人1：你好\n说话人2：再见');
  });
}
