import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../asr/capture_source.dart';
import '../asr/diarizer.dart';
import '../asr/transcript_segment.dart';
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

  @override
  void initState() {
    super.initState();
    _init();
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
    return Scaffold(
      appBar: AppBar(title: const Text('录音库')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.library_music,
                          size: 56, color: theme.colorScheme.outlineVariant),
                      const SizedBox(height: 12),
                      Text(
                        '还没有录音，去录一条吧',
                        style: TextStyle(
                            color: theme.colorScheme.outline, fontSize: 15),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  itemCount: _items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = _items[index];
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
                      subtitle: Text(
                        '${item.source == AudioSource.systemAudio ? '内录 · ' : ''}'
                        '${_fmtDate(item.createdAt)} · ${formatDuration(item.duration)} · $summary',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _showTranscript(item),
                      trailing: PopupMenuButton<String>(
                        onSelected: (action) {
                          switch (action) {
                            case 'rename':
                              _showRenameDialog(item);
                            case 'reanalyze':
                              _reanalyze(item);
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
    );
  }

  static String _fmtDate(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
