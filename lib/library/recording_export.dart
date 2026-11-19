import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'recordings_repository.dart';

/// Exports a recording's audio. Android summons the system share sheet
/// (save to Files, send via chat, …); desktop copies the WAV into a
/// user-chosen folder. Returns a user-facing message; throws on failure.
Future<String> exportAudio(Recording recording) async {
  final wav = File(recording.wavPath);
  if (!await wav.exists()) {
    throw Exception('音频文件不存在');
  }
  if (Platform.isAndroid) {
    await SharePlus.instance.share(ShareParams(
      subject: recording.title,
      files: [XFile(recording.wavPath)],
    ));
    return '已调出分享，可选择「保存到文件」或发送';
  }
  final dir = await FilePicker.getDirectoryPath(dialogTitle: '选择导出文件夹');
  if (dir == null) return '已取消导出';
  final target = p.join(dir, '${safeFileName(recording.title)}.wav');
  await wav.copy(target);
  return '音频已导出到 $target';
}

/// Exports the transcript (same content as 查看/复制全文) as a `.txt` file.
Future<String> exportTranscript(Recording recording) async {
  final text = recording.displayTranscript;
  if (text.isEmpty) throw Exception('暂无转写内容');
  if (Platform.isAndroid) {
    // The share sheet needs a file, not just text: hand it a temp copy.
    final tmp = await getTemporaryDirectory();
    final file = File(p.join(tmp.path, '${safeFileName(recording.title)}.txt'));
    await file.writeAsString(text);
    await SharePlus.instance.share(ShareParams(
      subject: recording.title,
      files: [XFile(file.path)],
    ));
    return '已调出分享，可选择「保存到文件」或发送';
  }
  final dir = await FilePicker.getDirectoryPath(dialogTitle: '选择导出文件夹');
  if (dir == null) return '已取消导出';
  final target = p.join(dir, '${safeFileName(recording.title)}.txt');
  await File(target).writeAsString(text);
  return '文本已导出到 $target';
}

/// Strips characters Windows forbids in file names.
String safeFileName(String title) {
  final cleaned = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  return cleaned.isEmpty ? 'recording' : cleaned;
}
