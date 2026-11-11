import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../theme.dart';

/// Card shown inside an assistant bubble for each tool invocation:
/// icon + tool name, argument summary, live status, optional screenshot
/// and expandable result.
class ToolCallCard extends StatefulWidget {
  const ToolCallCard({super.key, required this.call});

  final ToolCall call;

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _expanded = false;

  IconData get _icon {
    switch (widget.call.name) {
      case 'todo_write':
        return Icons.checklist_rounded;
      case 'browser_navigate':
        return Icons.travel_explore_rounded;
      case 'browser_click':
        return Icons.touch_app_rounded;
      case 'browser_type':
        return Icons.keyboard_rounded;
      case 'browser_scroll':
        return Icons.swipe_vertical_rounded;
      case 'browser_screenshot':
        return Icons.photo_camera_rounded;
      case 'browser_extract_text':
        return Icons.article_rounded;
      case 'run_js':
        return Icons.code_rounded;
      case 'read_file':
      case 'write_file':
        return Icons.description_rounded;
      default:
        return Icons.build_circle_rounded;
    }
  }

  Widget get _statusWidget {
    switch (widget.call.status) {
      case ToolStatus.pending:
        return Icon(
          Icons.hourglass_empty_rounded,
          size: 15,
          color: context.zMuted,
        );
      case ToolStatus.running:
        return const SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case ToolStatus.success:
        return const Icon(
          Icons.check_circle_rounded,
          size: 15,
          color: Color(0xFF4ADE80),
        );
      case ToolStatus.error:
        return const Icon(
          Icons.error_rounded,
          size: 15,
          color: Color(0xFFF87171),
        );
    }
  }

  void _openScreenshot(BuildContext context) {
    final String path = widget.call.screenshotPath!;
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(16),
        child: InteractiveViewer(
          maxScale: 5,
          // errorBuilder so a deleted file shows a message instead of an
          // unhandled image error.
          child: Image.file(
            File(path),
            fit: BoxFit.contain,
            errorBuilder:
                (BuildContext context, Object error, StackTrace? stack) =>
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        stringsOf(context).screenshotUnavailable,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                    ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final ToolCall call = widget.call;
    // Language-neutral summary from the model layer gets a localized label
    // for tools whose arguments are not user-readable.
    final String summary = call.argsSummary.isEmpty
        ? switch (call.name) {
            'browser_extract_text' => strings.readPageText,
            _ => '',
          }
        : call.argsSummary;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: context.zSurface,
        borderRadius: BorderRadius.circular(kCardRadius),
        border: Border.all(color: context.zBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(_icon, size: 16, color: kAccentColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  call.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              _statusWidget,
            ],
          ),
          if (summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: context.zMuted),
              ),
            ),
          if (call.screenshotPath != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: GestureDetector(
                onTap: () => _openScreenshot(context),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: Image.file(
                      File(call.screenshotPath!),
                      width: double.infinity,
                      fit: BoxFit.cover,
                      // v1.38.0: browser screenshots are full-screen
                      // bitmaps — decode at display resolution, not the
                      // source's 1080x1920, to keep scrolling smooth.
                      cacheWidth:
                          (MediaQuery.sizeOf(context).width *
                                  MediaQuery.devicePixelRatioOf(context))
                              .round(),
                      errorBuilder:
                          (
                            BuildContext context,
                            Object error,
                            StackTrace? stack,
                          ) => Container(
                            padding: const EdgeInsets.all(12),
                            color: context.zBackground,
                            child: Text(
                              strings.screenshotUnavailable,
                              style: TextStyle(
                                fontSize: 12,
                                color: context.zMuted,
                              ),
                            ),
                          ),
                    ),
                  ),
                ),
              ),
            ),
          if (call.resultText != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 2,
                    horizontal: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        call.status == ToolStatus.error
                            ? strings.resultError
                            : strings.result,
                        style: TextStyle(
                          fontSize: 11,
                          color: call.status == ToolStatus.error
                              ? const Color(0xFFF87171)
                              : context.zMuted,
                        ),
                      ),
                      Icon(
                        _expanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 14,
                        color: context.zMuted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_expanded && call.resultText != null)
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints(maxHeight: 160),
              decoration: BoxDecoration(
                color: context.zBackground,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  call.resultText!,
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    height: 1.4,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
