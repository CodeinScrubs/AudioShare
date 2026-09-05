import 'package:audioshare/l10n/generated/app_localizations.dart';
import 'package:audioshare/widgets/streaming_diagnostics_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'report stays selectable; refresh and copy use the visible snapshot',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var report = 'captured_frames=0';
      String? copiedText;
      var clipboardFails = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            if (clipboardFails) throw PlatformException(code: 'denied');
            copiedText = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: StreamingDiagnosticsDialog(
            deviceName: 'Test phone',
            readReport: () => report,
          ),
        ),
      );
      expect(find.text('captured_frames=0'), findsOneWidget);
    report = List.generate(70, (index) => 'metric_$index=48000').join('\n');
      await tester.tap(find.text('Copy report'));
      await tester.pump();
      expect(copiedText, 'captured_frames=0');
      expect(find.text('Copied'), findsOneWidget);
      await tester.tap(find.text('Refresh'));
      await tester.pump();
      expect(find.text(report), findsOneWidget);
      await tester.tap(find.text('Copy report'));
      await tester.pump();
      expect(copiedText, report);
      clipboardFails = true;
      await tester.tap(find.text('Copied'));
      await tester.pump();
      expect(find.textContaining('Could not copy.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
