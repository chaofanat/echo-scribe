import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

  void _showTranscript(Recording recording) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(recording.title),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: SelectableText(
              recording.transcript.isEmpty ? '（无转写内容）' : recording.transcript,
              style: const TextStyle(fontSize: 15, height: 1.7),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: recording.transcript));
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
