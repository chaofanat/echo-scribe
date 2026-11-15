/// One finalized transcript segment with its time span in the recording and,
/// once speaker diarization has run, the attributed speaker index (0-based,
/// null when no diarization turn overlaps the segment).
class TranscriptSegment {
  TranscriptSegment({
    required this.text,
    required this.startSec,
    required this.endSec,
    this.speaker,
  });

  final String text;
  final double startSec;
  final double endSec;
  int? speaker;

  Map<String, Object?> toJson() => {
        'text': text,
        'start': startSec,
        'end': endSec,
        'speaker': speaker,
      };

  static TranscriptSegment fromJson(Map<String, Object?> json) =>
      TranscriptSegment(
        text: json['text'] as String? ?? '',
        startSec: (json['start'] as num?)?.toDouble() ?? 0,
        endSec: (json['end'] as num?)?.toDouble() ?? 0,
        speaker: json['speaker'] as int?,
      );
}

/// Joins segments into a transcript, one line per segment (segments are
/// sentence-granular). The "说话人N：" prefix is written only when the
/// speaker changes; segments without an attributed speaker get no label.
String joinLabeledTranscript(List<TranscriptSegment> segments) {
  final buf = StringBuffer();
  int? prevSpeaker = _sentinel;
  for (final segment in segments) {
    final speaker = segment.speaker;
    if (speaker != prevSpeaker) {
      if (buf.isNotEmpty) buf.write('\n');
      if (speaker != null) buf.write('说话人${speaker + 1}：');
      prevSpeaker = speaker;
    } else if (buf.isNotEmpty) {
      // Sentence boundary within the same speaker's turn.
      buf.write('\n');
    }
    buf.write(segment.text);
  }
  return buf.toString();
}

/// Distinct from any valid speaker index so the first segment always opens a
/// new turn.
const _sentinel = -1;

/// Splits a finalized segment at sentence-ending punctuation (which the ASR
/// model places at actual sentence boundaries in the audio) into multiple
/// segments, dividing [TranscriptSegment.startSec]..[TranscriptSegment.endSec]
/// proportionally to character count. The speaker, if already set, is copied
/// to every piece.
List<TranscriptSegment> splitAtSentenceEnds(TranscriptSegment segment) {
  final text = segment.text;
  final pieces = <String>[];
  var pieceStart = 0;
  for (var i = 0; i < text.length; i++) {
    if (!_isSentenceEnd(text, i)) continue;
    // Extend over a run of terminators ("！！！") and trailing closing
    // quotes/brackets so they stay attached to the sentence they end.
    var end = i + 1;
    while (end < text.length && _endsWithSentence(text, end)) {
      end++;
    }
    pieces.add(text.substring(pieceStart, end));
    pieceStart = end;
    i = end - 1;
  }
  if (pieces.isEmpty) return [segment];
  final tail = text.substring(pieceStart);
  if (tail.trim().isNotEmpty) pieces.add(tail);

  // Divide the time span proportionally to character length.
  final total = pieces.fold<int>(0, (sum, piece) => sum + piece.length);
  final span = segment.endSec - segment.startSec;
  final result = <TranscriptSegment>[];
  var consumed = 0;
  var start = segment.startSec;
  for (final piece in pieces) {
    consumed += piece.length;
    final end = segment.startSec + span * consumed / total;
    result.add(TranscriptSegment(
      text: piece,
      startSec: start,
      endSec: end,
      speaker: segment.speaker,
    ));
    start = end;
  }
  return result;
}

/// Whether the character at [i] ends a sentence.
bool _isSentenceEnd(String text, int i) {
  final ch = text[i];
  if ('。！？!?；;'.contains(ch)) return true;
  if (ch != '.') return false;
  if (i == 0) return false;
  final next = i + 1 < text.length ? text[i + 1] : '';
  if (next.isEmpty) return true;
  if (next == '.') return false; // ellipsis / runs
  final code = next.codeUnitAt(0);
  if (code >= 0x30 && code <= 0x39) return false; // decimal like "3.14"
  return true;
}

/// Whether the character at [i] belongs to the just-ended sentence, i.e. is
/// another terminator or an unambiguous closing quote/bracket. ASCII quotes
/// are excluded because they open sentences as often as they close them.
bool _endsWithSentence(String text, int i) =>
    _isSentenceEnd(text, i) || '”’」』）)'.contains(text[i]);

/// Parses the `segments` array from a sidecar; tolerant of the field being
/// absent (recordings made before diarization existed) or malformed.
List<TranscriptSegment> parseSegments(Object? json) {
  if (json is! List) return [];
  return [
    for (final item in json)
      if (item is Map<String, Object?>)
        TranscriptSegment.fromJson(item),
  ];
}

/// Serializes segments for the sidecar (null to omit the key entirely);
/// `jsonEncode` is the caller's job.
Object? segmentsToJson(List<TranscriptSegment> segments) =>
    segments.isEmpty ? null : [for (final s in segments) s.toJson()];
