import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../asr/capture_source.dart';
import '../asr/diarizer.dart';
import '../asr/model_config.dart';
import '../asr/transcript_segment.dart';
import '../import/file_importer.dart';
import 'recording_filter.dart';
import 'recordings_repository.dart';
import '../utils/format.dart';

/// Lists saved recordings; supports viewing the transcript, renaming the
/// title and deleting (with confirmation).
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => LibraryPageState();
}

class LibraryPageState extends State<LibraryPage> {
  RecordingsRepository? _repo;
  List<Recording> _items = [];
  bool _loading = true;
  SpeakerDiarizer? _diarizer;
  bool _reanalyzing = false;

  final _searchController = TextEditingController();
  bool _searching = false;
  String _query = '';

  /// Active tag filter; null shows all recordings.
  String? _activeTag;

  bool _importing = false;
  double _importProgress = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final doc = await getApplicationDocumentsDirectory();
    _repo = RecordingsRepository(p.join(doc.path, 'EchoScribe', 'recordings'));
    await refresh();
  }

  /// Reloads the list from disk. Called after renames/deletes and when the
  /// tab becomes visible.
  Future<void> refresh() async {
    if (_repo == null) return;
    final items = await _repo!.list();
    if (mounted) {
      setState(() {
        _items = items;
        _loading = false;
      });
    }
  }

  Future<void> _confirmDelete(Recording recording) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除录音'),
        content: Text('确定删除「${recording.title}」？音频与转写均不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await _repo!.delete(recording);
      await refresh();
    }
  }

  Future<void> _showRenameDialog(Recording recording) async {
    final controller = TextEditingController(text: recording.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '录音标题'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (title != null && title.isNotEmpty && title != recording.title) {
      await _repo!.rename(recording, title);
      await refresh();
    }
  }

  /// Re-runs speaker diarization on a saved recording with an optionally
  /// forced speaker count, so a wrong attribution can be fixed without
  /// re-recording.
  Future<void> _reanalyze(Recording recording) async {
    if (_reanalyzing) return;
    if (recording.segments.isEmpty) {
      _snack('该录音缺少分段信息，无法重新分析');
      return;
    }
    final count = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('重新分析说话人'),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text('指定人数通常比自动检测更准确'),
          ),
          const SizedBox(height: 8),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 0),
            child: const Text('自动检测人数'),
          ),
          for (final n in const [2, 3, 4, 5, 6, 7, 8, 9, 10])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, n),
              child: Text('按 $n 人分析'),
            ),
        ],
      ),
    );
    if (count == null || !mounted) return;

    _reanalyzing = true;
    _snack('正在重新分析说话人…');
    try {
      _diarizer ??= await SpeakerDiarizer.create();
      final turns =
          await _diarizer!.analyze(recording.wavPath, numClusters: count);
      // Re-split stored segments at sentence punctuation so recordings made
      // before the split logic get sentence-granular attribution too.
      final segments = [
        for (final segment in recording.segments) ...splitAtSentenceEnds(segment),
      ];
      final speakerCount = attributeSpeakers(segments, turns);
      await _repo!.updateSegments(
        recording,
        segments,
        speakerCount,
        [for (final turn in turns) turn.toJson()],
      );
      await refresh();
      if (mounted) {
        final clusters = turns.map((turn) => turn.speaker).toSet().length;
        if (clusters > speakerCount) {
          _snack('已聚成 $clusters 类，$speakerCount 位说话人实际落到句子上'
              '（人数可能设置偏多，可换个数字重试）');
        } else {
          _snack('分析完成：识别到 $speakerCount 位说话人');
        }
      }
    } catch (e) {
      if (mounted) _snack('重新分析失败：$e');
    } finally {
      _reanalyzing = false;
    }
  }

  /// Tag editor: existing library tags as checkboxes plus free-text input
  /// for new ones; the result is written back to the sidecar.
  Future<void> _editTags(Recording recording) async {
    final all = [...collectTags(_items)];
    final selected = {...recording.tags};
    final input = TextEditingController();
    const dialogWidth = 360.0;

    void addTag(String raw, void Function(void Function()) setDialogState) {
      final tag = raw.trim();
      if (tag.isEmpty) return;
      setDialogState(() {
        selected.add(tag);
        if (!all.contains(tag)) all.insert(0, tag);
      });
      input.clear();
    }

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('编辑标签'),
          content: SizedBox(
            width: dialogWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final tag in all)
                        CheckboxListTile(
                          value: selected.contains(tag),
                          onChanged: (checked) => setDialogState(() => checked!
                              ? selected.add(tag)
                              : selected.remove(tag)),
                          title: Text(tag),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: input,
                        decoration: const InputDecoration(
                          hintText: '新标签',
                          isDense: true,
                        ),
                        onSubmitted: (value) => addTag(value, setDialogState),
                      ),
                    ),
                    IconButton(
                      tooltip: '添加标签',
                      icon: const Icon(Icons.add),
                      onPressed: () => addTag(input.text, setDialogState),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved ?? false) {
      await _repo!.updateTags(recording, selected.toList()..sort());
      await refresh();
    }
  }

  /// Picks an audio file (WAV/MP3/FLAC), transcribes it into the library
  /// and runs speaker diarization on the result.
  Future<void> _importFile() async {
    if (_importing || _repo == null) return;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['wav', 'mp3', 'flac'],
    );
    final sourcePath = picked?.files.single.path;
    if (sourcePath == null) return;

    setState(() {
      _importing = true;
      _importProgress = 0;
    });
    try {
      final modelFiles = await extractBundledAsrModel();
      final doc = await getApplicationDocumentsDirectory();
      final stem = p.basenameWithoutExtension(sourcePath);
      final now = DateTime.now();
      final stamp = '${now.year}${_two(now.month)}${_two(now.day)}-'
          '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
      final wavPath = p.join(
          doc.path, 'EchoScribe', 'recordings', 'import-$stem-$stamp.wav');

      final importer = FileImporter(modelFiles);
      final result = await importer.importFile(
        sourcePath,
        wavPath,
        onProgress: (progress) {
          if (mounted) setState(() => _importProgress = progress);
        },
      );

      final segments = [
        for (final utterance in result.utterances)
          ...splitAtSentenceEnds(TranscriptSegment(
            text: utterance.text,
            startSec: utterance.startSec,
            endSec: utterance.endSec,
          )),
      ];
      final recording = await _repo!.saveImported(
        wavPath: result.wavPath,
        title: stem,
        createdAt: now,
        duration: result.duration,
        transcript: segments.map((segment) => segment.text).join(),
        segments: segments,
      );
      await refresh();

      // Same auto-diarization as a live recording; failure is non-fatal.
      String? diarizeError;
      var speakerCount = 0;
      try {
        _diarizer ??= await SpeakerDiarizer.create();
        final turns = await _diarizer!.analyze(result.wavPath);
        if (turns.isNotEmpty) {
          speakerCount = attributeSpeakers(segments, turns);
          await _repo!.updateSegments(
            recording,
            segments,
            speakerCount,
            [for (final turn in turns) turn.toJson()],
          );
          await refresh();
        }
      } catch (e) {
        diarizeError = '$e';
      }
      if (!mounted) return;
      if (diarizeError != null) {
        _snack('导入完成，说话人分析失败：$diarizeError');
      } else if (speakerCount > 1) {
        _snack('导入完成：${segments.length} 段，识别到 $speakerCount 位说话人');
      } else {
        _snack('导入完成：${segments.length} 段');
      }
    } catch (e) {
      if (mounted) _snack('导入失败：$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _closeSearch() {
    _searchController.clear();
    setState(() {
      _searching = false;
      _query = '';
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showTranscript(Recording recording) {
    final text = recording.displayTranscript;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(recording.title),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: SelectableText(
              text.isEmpty ? '（无转写内容）' : text,
              style: const TextStyle(fontSize: 15, height: 1.7),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('转写已复制到剪贴板')),
              );
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tags = collectTags(_items);
    final filtered =
        filterRecordings(_items, query: _query, tag: _activeTag);

    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索标题或转写内容',
                  border: InputBorder.none,
                ),
                onChanged: (value) => setState(() => _query = value),
              )
            : const Text('录音库'),
        actions: [
          IconButton(
            tooltip: '导入音频转写',
            icon: const Icon(Icons.file_open),
            onPressed: _importing ? null : _importFile,
          ),
          if (_searching)
            IconButton(
              tooltip: '关闭搜索',
              icon: const Icon(Icons.close),
              onPressed: _closeSearch,
            )
          else
            IconButton(
              tooltip: '搜索',
              icon: const Icon(Icons.search),
              onPressed: () => setState(() => _searching = true),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? _emptyHint(theme, Icons.library_music, '还没有录音，去录一条吧')
              : Column(
                  children: [
                    if (_importing)
                      LinearProgressIndicator(
                        value: _importProgress <= 0 ? null : _importProgress,
                      ),
                    if (tags.isNotEmpty) ...[
                      _tagFilterRow(theme, tags),
                      const Divider(height: 1),
                    ],
                    Expanded(
                      child: filtered.isEmpty
                          ? _emptyHint(
                              theme, Icons.search_off, '没有匹配的录音')
                          : ListView.separated(
                              itemCount: filtered.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final item = filtered[index];
                                final summary = item.transcript.isEmpty
                                    ? '（无转写内容）'
                                    : item.transcript.replaceAll('\n', ' ');
                                return ListTile(
                                  leading: const Icon(Icons.graphic_eq),
                                  title: Text(
                                    item.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${_sourcePrefix(item.source)}'
                                        '${_fmtDate(item.createdAt)} · ${formatDuration(item.duration)} · $summary',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (item.tags.isNotEmpty)
                                        Text(
                                          item.tags
                                              .map((tag) => '#$tag')
                                              .join(' '),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color:
                                                theme.colorScheme.primary,
                                          ),
                                        ),
                                    ],
                                  ),
                                  onTap: () => _showTranscript(item),
                                  trailing: PopupMenuButton<String>(
                                    onSelected: (action) {
                                      switch (action) {
                                        case 'rename':
                                          _showRenameDialog(item);
                                        case 'reanalyze':
                                          _reanalyze(item);
                                        case 'tags':
                                          _editTags(item);
                                        case 'delete':
                                          _confirmDelete(item);
                                      }
                                    },
                                    itemBuilder: (context) => const [
                                      PopupMenuItem(
                                        value: 'rename',
                                        child: ListTile(
                                          leading: Icon(Icons.edit),
                                          title: Text('重命名'),
                                          contentPadding: EdgeInsets.zero,
                                          dense: true,
                                        ),
                                      ),
                                      PopupMenuItem(
                                        value: 'reanalyze',
                                        child: ListTile(
                                          leading: Icon(Icons.groups),
                                          title: Text('重新分析说话人'),
                                          contentPadding: EdgeInsets.zero,
                                          dense: true,
                                        ),
                                      ),
                                      PopupMenuItem(
                                        value: 'tags',
                                        child: ListTile(
                                          leading: Icon(Icons.sell),
                                          title: Text('编辑标签'),
                                          contentPadding: EdgeInsets.zero,
                                          dense: true,
                                        ),
                                      ),
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: ListTile(
                                          leading: Icon(Icons.delete),
                                          title: Text('删除'),
                                          contentPadding: EdgeInsets.zero,
                                          dense: true,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
    );
  }

  Widget _tagFilterRow(ThemeData theme, List<String> tags) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: const Text('全部'),
              selected: _activeTag == null,
              onSelected: (_) => setState(() => _activeTag = null),
            ),
          ),
          for (final tag in tags)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(tag),
                selected: _activeTag == tag,
                onSelected: (_) => setState(() => _activeTag = tag),
              ),
            ),
        ],
      ),
    );
  }

  Widget _emptyHint(ThemeData theme, IconData icon, String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: theme.colorScheme.outlineVariant),
          const SizedBox(height: 12),
          Text(
            message,
            style: TextStyle(color: theme.colorScheme.outline, fontSize: 15),
          ),
        ],
      ),
    );
  }

  static String _sourcePrefix(AudioSource source) => switch (source) {
        AudioSource.microphone => '',
        AudioSource.systemAudio => '内录 · ',
        AudioSource.imported => '导入 · ',
      };

  static String _fmtDate(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static String _two(int n) => n.toString().padLeft(2, '0');
}
