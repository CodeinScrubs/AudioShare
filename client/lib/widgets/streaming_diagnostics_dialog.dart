import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/generated/app_localizations.dart';

/// A stable, selectable snapshot. Refresh is deliberate so the text does not
/// move while the user selects it; Copy always copies the displayed snapshot.
class StreamingDiagnosticsDialog extends StatefulWidget {
  const StreamingDiagnosticsDialog({
    super.key,
    required this.deviceName,
    required this.readReport,
  });

  final String deviceName;
  final String Function() readReport;

  @override
  State<StreamingDiagnosticsDialog> createState() =>
      _StreamingDiagnosticsDialogState();
}

class _StreamingDiagnosticsDialogState
    extends State<StreamingDiagnosticsDialog> {
  late String _report;
  bool _copied = false;
  bool _copyFailed = false;

  @override
  void initState() {
    super.initState();
    _report = widget.readReport();
  }

  Future<void> _copy() async {
    final report = _report;
    try {
      await Clipboard.setData(ClipboardData(text: report));
      if (!mounted || _report != report) return;
      setState(() {
        _copied = true;
        _copyFailed = false;
      });
    } catch (_) {
      if (!mounted || _report != report) return;
      setState(() {
        _copied = false;
        _copyFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text('${l10n.streamingDiagnostics} — ${widget.deviceName}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_copyFailed) Text(l10n.copyDiagnosticsFailed),
            SelectableText(
              _report,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() {
            _report = widget.readReport();
            _copied = false;
            _copyFailed = false;
          }),
          child: Text(l10n.refreshDiagnostics),
        ),
        TextButton(
          onPressed: _copy,
          child: Text(_copied ? l10n.diagnosticsCopied : l10n.copyDiagnostics),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.ok),
        ),
      ],
    );
  }
}
