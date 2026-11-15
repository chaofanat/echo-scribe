import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'asr/recognizer.dart';
import 'asr/recording_session.dart';

void main() {
  runApp(const EchoScribeApp());
}

class EchoScribeApp extends StatelessWidget {
  const EchoScribeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EchoScribe',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  StreamingRecognizer? _recognizer;
  bool _loadingRecognizer = false;
  RecordingSession? _session;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _session?.dispose();
    _recognizer?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _isRecording =>
      _session?.status == SessionStatus.recording;

  Future<void> _toggleRecording() async {
    final session = _session;
    if (session != null) {
      if (session.status == SessionStatus.recording) {
        await session.stop();
        if (mounted && session.savedFile != null) {
          _snack('录音已保存');
        }
        return;
      }
      await _startSession(session);
      return;
    }

    if (_recognizer == null) {
      setState(() => _loadingRecognizer = true);
      try {
        _recognizer = await StreamingRecognizer.create();
      } catch (e) {
        if (mounted) {
          _snack('模型加载失败：请先运行 scripts/download_model.ps1 下载模型');
        }
        debugPrint('recognizer create failed: $e');
      } finally {
        if (mounted) setState(() => _loadingRecognizer = false);
      }
      if (_recognizer == null) return;
    }
    await _startSession(RecordingSession(_recognizer!));
  }

  Future<void> _startSession(RecordingSession session) async {
    try {
      await session.start();
    } catch (e) {
      if (mounted) _snack('无法开始录音：$e');
      return;
    }
    session.addListener(_onSessionChanged);
    setState(() => _session = session);
  }

  void _onSessionChanged() {
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _copyTranscript() async {
    final text = _session?.transcript ?? '';
    if (text.isEmpty) {
      _snack('暂无转写内容');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _snack('转写已复制到剪贴板');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _fmtDuration(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0
        ? '$h:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}'
        : '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final theme = Theme.of(context);
    final hasTranscript = (session?.transcript ?? '').isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('EchoScribe'),
        actions: [
          IconButton(
            tooltip: '复制全文',
            icon: const Icon(Icons.copy),
            onPressed: _copyTranscript,
          ),
        ],
      ),
      body: Column(
        children: [
          _statusRow(theme, session),
          const Divider(height: 1),
          Expanded(
            child: !hasTranscript && !_isRecording
                ? _emptyHint(theme)
                : ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final segment in session!.segments)
                        Text(
                          segment,
                          style: const TextStyle(
                            fontSize: 17,
                            height: 1.7,
                          ),
                        ),
                      if (session.partial.isNotEmpty)
                        Text(
                          session.partial,
                          style: TextStyle(
                            fontSize: 17,
                            height: 1.7,
                            color: theme.colorScheme.outline,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                    ],
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: _recordButton(theme),
          ),
        ],
      ),
    );
  }

  Widget _statusRow(ThemeData theme, RecordingSession? session) {
    final recording = session?.status == SessionStatus.recording;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(
            recording ? Icons.fiber_manual_record : Icons.mic_off,
            size: 16,
            color: recording ? theme.colorScheme.error : theme.colorScheme.outline,
          ),
          const SizedBox(width: 8),
          Text(
            recording
                ? '录音中 ${_fmtDuration(session!.elapsed)}'
                : '未在录音',
            style: TextStyle(
              color: recording ? theme.colorScheme.error : theme.colorScheme.outline,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          if (session?.savedFile case final path?)
            Expanded(
              child: Text(
                path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _emptyHint(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.graphic_eq, size: 56, color: theme.colorScheme.outlineVariant),
          const SizedBox(height: 12),
          Text(
            _loadingRecognizer ? '正在加载模型…' : '点击下方按钮开始录音',
            style: TextStyle(color: theme.colorScheme.outline, fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _recordButton(ThemeData theme) {
    if (_loadingRecognizer) {
      return const SizedBox(
        width: 64,
        height: 64,
        child: CircularProgressIndicator(strokeWidth: 3),
      );
    }
    final recording = _isRecording;
    return ClipOval(
      child: Material(
        color: recording
            ? theme.colorScheme.error
            : theme.colorScheme.primary,
        child: InkWell(
          onTap: _toggleRecording,
          child: SizedBox(
            width: 64,
            height: 64,
            child: Icon(
              recording ? Icons.stop : Icons.mic,
              color: theme.colorScheme.onPrimary,
              size: 30,
            ),
          ),
        ),
      ),
    );
  }
}
