import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../theme.dart';

/// Dedicated Help screen (v1.41.5): the complete user guide — every feature
/// explained in plain language, one expandable section per topic, placed
/// above About in Settings. All content is bilingual via [AppStrings].
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final ZPalette palette = context.palette;
    final List<HelpEntry> topics = strings.helpTopics;
    return Scaffold(
      appBar: AppBar(title: Text(strings.helpTitle)),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // -- Intro -----------------------------------------------------
              Card(
                color: context.zSurface,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(kCardRadius),
                  side: BorderSide(color: context.zBorder),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          gradient: kBrandGradient,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.help_outline_rounded,
                          color: Colors.white,
                          size: 26,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          strings.helpIntro,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.5,
                            color: palette.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // -- Topics ----------------------------------------------------
              for (var i = 0; i < topics.length; i++) ...<Widget>[
                _HelpTopicCard(
                  key: Key('help-topic-$i'),
                  index: i,
                  entry: topics[i],
                  initiallyExpanded: i == 0,
                ),
                const SizedBox(height: 10),
              ],
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// One expandable help topic. Collapsed by default (except the first) so the
/// guide stays scannable; each card keeps a subtle border like every other
/// surface in the app.
class _HelpTopicCard extends StatelessWidget {
  const _HelpTopicCard({
    super.key,
    required this.index,
    required this.entry,
    required this.initiallyExpanded,
  });

  final int index;
  final HelpEntry entry;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final ZPalette palette = context.palette;
    return Card(
      color: context.zSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kCardRadius),
        side: BorderSide(color: context.zBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // Remove the default tile divider splash; keep the app's own look.
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          initiallyExpanded: initiallyExpanded,
          iconColor: palette.muted,
          collapsedIconColor: palette.muted,
          title: Text(
            entry.title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          children: <Widget>[
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                entry.body,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: palette.muted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
