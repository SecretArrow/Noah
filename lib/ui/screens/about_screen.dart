import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../theme.dart';

/// App version shown on the About screen. Kept in sync with pubspec.yaml at
/// every release bump (the release pipeline's quality gate reads pubspec).
const String kAppVersion = '1.0.0';

/// Dedicated About screen (v1.41.5): a tidy, structured presentation of the
/// app identity — version, creator, capabilities and the honest disclaimer —
/// replacing the old cramped settings card.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final ZPalette palette = context.palette;
    return Scaffold(
      appBar: AppBar(title: Text(strings.aboutTitle)),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // -- Identity header ------------------------------------------
              Card(
                key: const Key('about-header'),
                color: context.zSurface,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(kCardRadius),
                  side: BorderSide(color: context.zBorder),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: <Widget>[
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          gradient: kBrandGradient,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: const Icon(
                          Icons.smart_toy_rounded,
                          color: Colors.white,
                          size: 40,
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Noah',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        strings.aboutTagline,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.45,
                          color: palette.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // -- Facts: version + creator ---------------------------------
              Card(
                color: context.zSurface,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(kCardRadius),
                  side: BorderSide(color: context.zBorder),
                ),
                child: Column(
                  children: <Widget>[
                    ListTile(
                      key: const Key('about-version'),
                      leading: const Icon(Icons.tag_rounded, size: 22),
                      title: Text(strings.aboutVersionLabel),
                      trailing: Text(
                        kAppVersion,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          fontFeatures: <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ),
                    Divider(height: 1, color: context.zBorder),
                    ListTile(
                      key: const Key('about-creator'),
                      leading: const Icon(Icons.code_rounded, size: 22),
                      title: Text(strings.aboutCreatorLabel),
                      trailing: const Text(
                        'Maragung',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // -- What's inside --------------------------------------------
              _aboutCard(
                context: context,
                palette: palette,
                icon: Icons.widgets_outlined,
                title: strings.aboutWhatsInside,
                body: strings.aboutBody,
              ),
              const SizedBox(height: 16),
              // -- Honest disclaimer ----------------------------------------
              _aboutCard(
                context: context,
                palette: palette,
                icon: Icons.verified_user_outlined,
                title: strings.helpTitle,
                body: strings.aboutDisclaimer,
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _aboutCard({
    required BuildContext context,
    required ZPalette palette,
    required IconData icon,
    required String title,
    required String body,
  }) {
    return Card(
      color: context.zSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kCardRadius),
        side: BorderSide(color: context.zBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon, size: 20, color: palette.muted),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              body,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.55,
                color: palette.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
