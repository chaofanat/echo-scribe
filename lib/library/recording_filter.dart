import 'recordings_repository.dart';

/// Case-insensitive substring match over title and transcript. An empty
/// query matches everything.
bool matchesQuery(Recording recording, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return recording.title.toLowerCase().contains(q) ||
      recording.transcript.toLowerCase().contains(q);
}

/// Distinct tags across [recordings], most-used first, ties in A-Z order.
List<String> collectTags(List<Recording> recordings) {
  final counts = <String, int>{};
  for (final recording in recordings) {
    for (final tag in recording.tags) {
      counts[tag] = (counts[tag] ?? 0) + 1;
    }
  }
  return counts.keys.toList()
    ..sort((a, b) {
      final byCount = counts[b]!.compareTo(counts[a]!);
      return byCount != 0 ? byCount : a.compareTo(b);
    });
}

/// Applies the library search box ([query]) and the active tag filter
/// ([tag], null = no filter) on top of the newest-first list.
List<Recording> filterRecordings(
  List<Recording> recordings, {
  String query = '',
  String? tag,
}) {
  return recordings
      .where((recording) =>
          matchesQuery(recording, query) &&
          (tag == null || recording.tags.contains(tag)))
      .toList();
}
