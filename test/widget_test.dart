import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:echo_scribe/main.dart';

void main() {
  testWidgets('home screen shows empty hint and record button', (tester) async {
    await tester.pumpWidget(const EchoScribeApp());

    expect(find.text('EchoScribe'), findsOneWidget);
    expect(find.text('点击下方按钮开始录音'), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsOneWidget);
  });
}
