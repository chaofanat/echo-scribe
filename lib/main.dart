import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'asr/capture_source.dart';
import 'asr/diarizer.dart';
import 'asr/recognizer.dart';
import 'asr/recording_session.dart';
import 'library/library_page.dart';
import 'platform/background_recording.dart';
import 'utils/format.dart';

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
      home: const HomeShell(),
    );
  }
}

/// Bottom-navigation shell hosting the recorder and the library tabs.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  final _libraryKey = GlobalKey<LibraryPageState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          const RecorderPage(),
          LibraryPage(key: _libraryKey),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) {
          setState(() => _tab = index);
          // Pick up recordings saved since the library was last visible.
          if (index == 1) _libraryKey.currentState?.refresh();
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.mic), label: '录音'),
          NavigationDestination(icon: Icon(Icons.library_music), label: '录音库'),
        ],
      ),
    );
  }
}

class RecorderPage extends StatefulWidget {
  const RecorderPage({super.key});

  @override
  State<RecorderPage> createState() => _RecorderPageState();
}

class _RecorderPageState extends State<RecorderPage> {
  StreamingRecognizer? _recognizer;
  SpeakerDiarizer? _diarizer;
  bool _loadingRecognizer = false;
  RecordingSession? _session;
  final _scroll = ScrollController();

  /// Speaker-count hint for diarization clustering: 0 = auto.
  int _expectedSpeakers = 0;

  /// Capture device for the next recording; system audio is Windows-only
  /// (WASAPI loopback).
  AudioSource _source = AudioSource.microphone;
  bool _wasDiarizing = false;

  @override
  void dispose() {
    // Safety net: never leave the keep-alive service's notification behind.
    BackgroundRecording.stop();
    _session?.dispose();
    _recognizer?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _isRecording => _session?.status == SessionStatus.recording;

  Future<void> _toggleRecording() async {
    final session = _session;
    if (session != null) {
      if (session.status == SessionStatus.recording) {
        await session.stop();
        await BackgroundRecording.stop();
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
        // Diarization is optional: a failure here only means recordings are
        // saved without speaker labels.
        try {
          _diarizer = await SpeakerDiarizer.create();
        } catch (e) {
          debugPrint('diarizer create failed: $e');
        }
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
    await _startSession(
      RecordingSession(_recognizer!, _diarizer, _expectedSpeakers, _source),
    );
  }

  Future<void> _startSession(RecordingSession session) async {
    try {
      await session.start();
    } catch (e) {
      if (mounted) _snack('无法开始录音：$e');
      return;
    }
    // Android only: keep capture + recognition running when the app is
    // backgrounded or the screen turns off.
    await BackgroundRecording.start();
    session.addListener(_onSessionChanged);
    setState(() => _session = session);
  }

  void _onSessionChanged() {
    setState(() {});
    final session = _session;
    // Diarization just finished: tell the user what came out so a "1
    // speaker" result is visible instead of silently hiding all labels.
    if (session != null && _wasDiarizing && !session.diarizing) {
      final error = session.diarizeError;
      if (error != null) {
        _snack(error);
      } else if (session.speakerCount > 1) {
        if (session.speakerClusters > session.speakerCount) {
          _snack(
            '已聚成 ${session.speakerClusters} 类，${session.speakerCount} 位说话人实际落到句子上'
            '（人数可能设置偏多，可重新分析调整）',
          );
        } else {
          _snack('已识别到 ${session.speakerCount} 位说话人');
        }
      } else if (session.speakerCount == 1) {
        _snack('仅识别到 1 位说话人（可在录音库中重新分析并指定人数）');
      } else {
        _snack('说话人分析未产生结果');
      }
    }
    _wasDiarizing = session?.diarizing ?? false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _copyTranscript() async {
    final text = _session?.labeledTranscript ?? '';
    if (text.isEmpty) {
      _snack('暂无转写内容');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _snack('转写已复制到剪贴板');
  }

  PopupMenuEntry<String> _speakerCountItem(int value, String label) =>
      CheckedPopupMenuItem(
        value: value.toString(),
        checked: _expectedSpeakers == value,
        child: Text(label),
      );

  /// Switches the capture device used by the next recording. Blocked while
  /// recording so a session never mixes two devices.
  void _selectSource(String value) {
    if (_isRecording) {
      _snack('录音中无法切换音源，请先停止录音');
      return;
    }
    final source = AudioSource.fromId(value);
    if (source == _source) return;
    setState(() => _source = source);
    // The session object outlives a recording (its transcript stays on
    // screen); it reads [RecordingSession.source] when starting.
    _session?.source = source;
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
          if (Platform.isWindows)
            PopupMenuButton<String>(
              tooltip: '录音来源',
              icon: Icon(
                _source == AudioSource.systemAudio
                    ? Icons.volume_up
                    : Icons.mic,
              ),
              onSelected: _selectSource,
              itemBuilder: (_) => [
                CheckedPopupMenuItem(
                  value: AudioSource.microphone.id,
                  checked: _source == AudioSource.microphone,
                  child: const Text('麦克风'),
                ),
                CheckedPopupMenuItem(
                  value: AudioSource.systemAudio.id,
                  checked: _source == AudioSource.systemAudio,
                  child: const Text('系统声音（内录）'),
                ),
              ],
            ),
          PopupMenuButton<String>(
            tooltip: '说话人数',
            icon: const Icon(Icons.groups),
            onSelected: (value) =>
                setState(() => _expectedSpeakers = int.parse(value)),
            itemBuilder: (_) => [
              _speakerCountItem(0, '自动检测'),
              for (final n in const [2, 3, 4, 5, 6, 7, 8, 9, 10])
                _speakerCountItem(n, '$n 人'),
            ],
          ),
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
                      for (var i = 0; i < session!.segments.length; i++)
                        _segmentText(session, i),
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

  /// One finalized segment; prefixes a "说话人N" label whenever the speaker
  /// differs from the previous segment (labels only appear after
  /// diarization ran and found more than one speaker).
  Widget _segmentText(RecordingSession session, int index) {
    final segment = session.segments[index];
    final speaker = segment.speaker;
    final startsTurn =
        session.speakerCount > 1 &&
        speaker != null &&
        (index == 0 || session.segments[index - 1].speaker != speaker);
    if (!startsTurn) {
      return Text(
        segment.text,
        style: const TextStyle(fontSize: 17, height: 1.7),
      );
    }
    final theme = Theme.of(context);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '说话人${speaker + 1}　',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.primary,
            ),
          ),
          TextSpan(text: segment.text),
        ],
      ),
      style: const TextStyle(fontSize: 17, height: 1.7),
    );
  }

  Widget _statusRow(ThemeData theme, RecordingSession? session) {
    final recording = session?.status == SessionStatus.recording;
    final analyzing = session?.diarizing == true;
    final loopback = session?.source == AudioSource.systemAudio;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(
            recording
                ? (loopback ? Icons.volume_up : Icons.fiber_manual_record)
                : analyzing
                ? Icons.groups
                : Icons.mic_off,
            size: 16,
            color: recording
                ? theme.colorScheme.error
                : analyzing
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
          ),
          const SizedBox(width: 8),
          Text(
            recording
                ? (loopback
                      ? '内录系统声音中 ${formatDuration(session!.elapsed)}'
                      : '录音中 ${formatDuration(session!.elapsed)}')
                : analyzing
                ? '正在分析说话人…'
                : '未在录音',
            style: TextStyle(
              color: recording
                  ? theme.colorScheme.error
                  : analyzing
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
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
          Icon(
            Icons.graphic_eq,
            size: 56,
            color: theme.colorScheme.outlineVariant,
          ),
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
    final analyzing = _session?.diarizing == true;
    return ClipOval(
      child: Material(
        color: recording ? theme.colorScheme.error : theme.colorScheme.primary,
        child: Semantics(
          button: true,
          label: recording ? '停止录音' : '开始录音',
          child: Tooltip(
            message: recording ? '停止录音' : '开始录音',
            child: InkWell(
              // Blocked while the finished recording is still being analyzed.
              onTap: analyzing ? null : _toggleRecording,
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
        ),
      ),
    );
  }
}
