import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Starts/stops the Android foreground service that keeps a recording
/// alive when the app goes to the background or the screen turns off
/// (microphone-type foreground service + partial wake lock, see
/// `RecordingService.kt`). A no-op on other platforms; failures are
/// logged, never fatal — recording still works while the app is visible.
class BackgroundRecording {
  static const _channel = MethodChannel('echo_scribe/background');

  static Future<void> start() => _invoke('start');

  static Future<void> stop() => _invoke('stop');

  static Future<void> _invoke(String method) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>(method);
    } catch (e) {
      debugPrint('background recording "$method" failed: $e');
    }
  }
}
