import 'package:flutter_test/flutter_test.dart';

import 'package:echo_scribe/asr/diarizer.dart';
import 'package:echo_scribe/asr/transcript_segment.dart';

TranscriptSegment seg(String text, double start, double end) =>
    TranscriptSegment(text: text, startSec: start, endSec: end);

void main() {
  group('attributeSpeakers', () {
    test('assigns the turn with the largest overlap', () {
      final segments = [
        seg('你好', 0, 3),
        seg('再见', 3.5, 6),
      ];
      final turns = [
        const SpeakerTurn(startSec: 0, endSec: 3.2, speaker: 0),
        const SpeakerTurn(startSec: 3.2, endSec: 6, speaker: 1),
        // Overlaps both segments but less than the dedicated turns.
        const SpeakerTurn(startSec: 2.9, endSec: 3.5, speaker: 0),
      ];

      final count = attributeSpeakers(segments, turns);

      expect(count, 2);
      expect(segments.first.speaker, 0);
      expect(segments.last.speaker, 1);
    });

    test('segment without any overlap keeps a null speaker', () {
      final segments = [seg('静音后的一句', 10, 12)];
      const turns = [SpeakerTurn(startSec: 0, endSec: 5, speaker: 0)];

      final count = attributeSpeakers(segments, turns);

      // No segment was attributed, so no distinct speakers are reported.
      expect(count, 0);
      expect(segments.single.speaker, isNull);
    });

    test('renumbers sparse speaker ids by first appearance', () {
      final segments = [
        seg('a', 0, 1),
        seg('b', 1, 2),
        seg('c', 2, 3),
      ];
      final turns = [
        const SpeakerTurn(startSec: 0, endSec: 1, speaker: 3),
        const SpeakerTurn(startSec: 1, endSec: 2, speaker: 7),
        const SpeakerTurn(startSec: 2, endSec: 3, speaker: 3),
      ];

      final count = attributeSpeakers(segments, turns);

      expect(count, 2);
      expect(segments.map((s) => s.speaker), [0, 1, 0]);
    });

    test('empty turns leave everything unlabeled', () {
      final segments = [seg('a', 0, 1)];

      expect(attributeSpeakers(segments, const []), 0);
      expect(segments.single.speaker, isNull);
    });
  });

  group('joinLabeledTranscript', () {
    test('one line per sentence, label only when the speaker changes', () {
      final segments = [
        seg('你好。', 0, 2)..speaker = 0,
        seg('很高兴见到你。', 2, 4)..speaker = 0,
        seg('我也是。', 4, 6)..speaker = 1,
      ];

      expect(
        joinLabeledTranscript(segments),
        '说话人1：你好。\n很高兴见到你。\n说话人2：我也是。',
      );
    });

    test('unlabeled segments join without a prefix', () {
      final segments = [
        seg('你好。', 0, 2),
        seg('再见。', 2, 4),
      ];

      expect(joinLabeledTranscript(segments), '你好。\n再见。');
    });

    test('speaker change back and forth opens a new turn each time', () {
      final segments = [
        seg('a', 0, 1)..speaker = 0,
        seg('b', 1, 2)..speaker = 1,
        seg('c', 2, 3)..speaker = 0,
      ];

      expect(
        joinLabeledTranscript(segments),
        '说话人1：a\n说话人2：b\n说话人1：c',
      );
    });
  });

  group('splitAtSentenceEnds', () {
    test('splits at sentence punctuation with proportional time spans', () {
      final result = splitAtSentenceEnds(
        TranscriptSegment(text: '今天讨论项目进度。你觉得怎么样？还可以。', startSec: 10, endSec: 20),
      );

      expect(result.map((s) => s.text), [
        '今天讨论项目进度。',
        '你觉得怎么样？',
        '还可以。',
      ]);
      // Times are monotonic and cover the whole span.
      expect(result.first.startSec, 10);
      expect(result.last.endSec, 20);
      for (var i = 1; i < result.length; i++) {
        expect(result[i].startSec, result[i - 1].endSec);
      }
    });

    test('text without terminators stays one segment', () {
      final segment = TranscriptSegment(text: '没有标点的一句话', startSec: 0, endSec: 3);
      expect(splitAtSentenceEnds(segment), [same(segment)]);
    });

    test('trailing text without punctuation becomes the last piece', () {
      final result = splitAtSentenceEnds(
        TranscriptSegment(text: '第一句。后面还有话', startSec: 0, endSec: 6),
      );
      expect(result.map((s) => s.text), ['第一句。', '后面还有话']);
    });

    test('decimals and ellipses are not sentence ends', () {
      final text = '圆周率是3.14等等…大概就是这样';
      final result =
          splitAtSentenceEnds(TranscriptSegment(text: text, startSec: 0, endSec: 5));
      expect(result, hasLength(1));
      expect(result.single.text, text);
    });

    test('terminator runs and closing quotes stay attached', () {
      final result = splitAtSentenceEnds(
        TranscriptSegment(text: '真的吗？！“那就好。”继续说', startSec: 0, endSec: 8),
      );
      expect(result.map((s) => s.text), ['真的吗？！', '“那就好。”', '继续说']);
    });

    test('speaker is copied to every piece', () {
      final result = splitAtSentenceEnds(
        TranscriptSegment(text: 'a。b。', startSec: 0, endSec: 4)..speaker = 1,
      );
      expect(result.every((s) => s.speaker == 1), isTrue);
    });

    test('split stays within each original final, boundaries are kept', () {
      // Two consecutive ASR finals; punctuation splitting runs inside each
      // one and never merges text across the original boundary.
      final first = splitAtSentenceEnds(
        TranscriptSegment(text: '今天开会。讨论方案', startSec: 0, endSec: 10),
      );
      final second = splitAtSentenceEnds(
        TranscriptSegment(text: '散会', startSec: 10, endSec: 12),
      );

      expect(first.map((s) => s.text), ['今天开会。', '讨论方案']);
      expect(second.map((s) => s.text), ['散会']);
      expect(first.last.endSec, second.first.startSec);
    });
  });

  group('TranscriptSegment json', () {
    test('round-trips through json', () {
      final original = seg('你好', 1.5, 2.5)..speaker = 1;

      final restored =
          TranscriptSegment.fromJson(original.toJson());

      expect(restored.text, '你好');
      expect(restored.startSec, 1.5);
      expect(restored.endSec, 2.5);
      expect(restored.speaker, 1);
    });

    test('parses segments arrays tolerantly', () {
      expect(parseSegments(null), isEmpty);
      expect(parseSegments('not a list'), isEmpty);
      expect(parseSegments([
        {'text': '你好', 'start': 0, 'end': 1, 'speaker': null},
        'garbage entry',
      ]), hasLength(1));
    });
  });
}
