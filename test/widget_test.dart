import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:echo_scribe/main.dart';

class FakePathProvider extends PathProviderPlatform {
  FakePathProvider(this.docDir);

  final String docDir;

  @override
  Future<String?> getApplicationDocumentsPath() async => docDir;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docTmp;

  setUp(() {
    docTmp = Directory.systemTemp.createTempSync('echoscribe_ui_');
    PathProviderPlatform.instance = FakePathProvider(docTmp.path);
  });

  tearDown(() {
    // Sync IO: awaiting real IO in the fake-async zone would hang the test.
    docTmp.deleteSync(recursive: true);
  });

  testWidgets('recorder tab shows empty hint and record button',
      (tester) async {
    await tester.pumpWidget(const EchoScribeApp());

    expect(find.text('EchoScribe'), findsOneWidget);
    expect(find.text('点击下方按钮开始录音'), findsOneWidget);
    // NavigationBar tab icon + the record button.
    expect(find.byIcon(Icons.mic), findsNWidgets(2));
  });

  testWidgets('library tab lists saved recordings', (tester) async {
    final recDir = Directory('${docTmp.path}/EchoScribe/recordings')
      ..createSync(recursive: true);
    // Same fake-async caveat: write the fixture via sync IO.
    File('${recDir.path}/rec-test.wav').writeAsBytesSync(List.filled(10, 0));
    File('${recDir.path}/rec-test.json').writeAsStringSync(jsonEncode({
      'title': '测试录音',
      'createdAt': DateTime(2026, 1, 1).toIso8601String(),
      'durationMs': 65000,
      'transcript': '你好世界',
    }));

    await tester.pumpWidget(const EchoScribeApp());
    await tester.tap(find.text('录音库'));
    await _pumpUntilFound(tester, find.text('测试录音'));

    expect(find.text('测试录音'), findsOneWidget);
    expect(find.textContaining('01:05'), findsOneWidget);
    expect(find.textContaining('你好世界'), findsOneWidget);
  });

  testWidgets('library tab shows empty hint when no recordings',
      (tester) async {
    await tester.pumpWidget(const EchoScribeApp());
    await tester.tap(find.text('录音库'));
    await _pumpUntilFound(tester, find.text('还没有录音，去录一条吧'));

    expect(find.text('还没有录音，去录一条吧'), findsOneWidget);
  });
}

/// The library loads via real disk IO, which fake-async tests must let run
/// explicitly. Polls with small real-time slices until [finder] matches.
Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 30 && finder.evaluate().isEmpty; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
  }
}
