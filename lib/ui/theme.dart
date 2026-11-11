import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// -- Dark palette -------------------------------------------------------------
const Color kBackgroundColor = Color(0xFF131316);
const Color kSurfaceColor = Color(0xFF1C1C1F);
const Color kSurfaceAltColor = Color(0xFF26262B);
const Color kBorderColor = Color(0xFF2E2E33);
const Color kAccentColor = Color(0xFF2563EB);
const Color kAccent2Color = Color(0xFF1D4ED8);
const Color kMutedTextColor = Color(0xFF9CA3AF);

// -- Light palette ------------------------------------------------------------
const Color kLightBackgroundColor = Color(0xFFF7F7F9);
const Color kLightSurfaceColor = Color(0xFFFFFFFF);
const Color kLightSurfaceAltColor = Color(0xFFECECF1);
const Color kLightBorderColor = Color(0xFFE4E4EA);
const Color kLightMutedTextColor = Color(0xFF6B7280);

// -- Scheme accents per brightness ---------------------------------------------
// The brand blue is slightly brighter in the dark theme; the soft tinted
// container backs the selected-pill highlights in the drawer and the
// bottom navigation.
const Color kPrimaryDarkColor = Color(0xFF2C6BED);
const Color kSecondaryContainerLightColor = Color(0xFFE8EEFB);
const Color kSecondaryContainerDarkColor = Color(0xFF22293C);
const Color kLightOnSurfaceColor = Color(0xFF1B1B1F);
const Color kDarkOnSurfaceColor = Color(0xFFE8E8ED);

// -- Shape tokens (single source of truth) --------------------------------------
const double kBubbleRadius = 20;
const double kBubbleTailRadius = 6;
const double kComposerRadius = 26;
const double kCardRadius = 18;
const double kDialogRadius = 24;
const double kNavPillRadius = 32;
const double kPillRadius = 50;

const LinearGradient kBrandGradient = LinearGradient(
  colors: <Color>[kAccentColor, kAccent2Color],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

/// Brightness-resolved palette so every widget can adapt to the active
/// theme without hardcoding dark colors.
class ZPalette {
  const ZPalette({
    required this.background,
    required this.surface,
    required this.surfaceAlt,
    required this.border,
    required this.muted,
  });

  final Color background;
  final Color surface;
  final Color surfaceAlt;
  final Color border;
  final Color muted;

  static const ZPalette dark = ZPalette(
    background: kBackgroundColor,
    surface: kSurfaceColor,
    surfaceAlt: kSurfaceAltColor,
    border: kBorderColor,
    muted: kMutedTextColor,
  );

  static const ZPalette light = ZPalette(
    background: kLightBackgroundColor,
    surface: kLightSurfaceColor,
    surfaceAlt: kLightSurfaceAltColor,
    border: kLightBorderColor,
    muted: kLightMutedTextColor,
  );
}

/// Theme-aware palette access: `context.palette.surface` etc.
extension ZPaletteX on BuildContext {
  ZPalette get palette => Theme.of(this).brightness == Brightness.dark
      ? ZPalette.dark
      : ZPalette.light;
  Color get zBackground => palette.background;
  Color get zSurface => palette.surface;
  Color get zSurfaceAlt => palette.surfaceAlt;
  Color get zBorder => palette.border;
  Color get zMuted => palette.muted;
}

ThemeData _baseTheme(Brightness brightness) {
  final bool isDark = brightness == Brightness.dark;
  final ZPalette p = isDark ? ZPalette.dark : ZPalette.light;
  final ColorScheme scheme =
      ColorScheme.fromSeed(
        seedColor: kAccentColor,
        brightness: brightness,
        surface: p.surface,
      ).copyWith(
        primary: isDark ? kPrimaryDarkColor : kAccentColor,
        onPrimary: Colors.white,
        onSurface: isDark ? kDarkOnSurfaceColor : kLightOnSurfaceColor,
        secondaryContainer: isDark
            ? kSecondaryContainerDarkColor
            : kSecondaryContainerLightColor,
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.background,
    appBarTheme: AppBarTheme(
      backgroundColor: p.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      // Transparent system bars with icons that contrast the app background
      // in both themes (edge-to-edge is enforced on Android 15+).
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: isDark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      ),
    ),
    dividerColor: p.border,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surfaceAlt,
      hintStyle: TextStyle(color: p.muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kComposerRadius),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kComposerRadius),
        borderSide: BorderSide(color: p.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kComposerRadius),
        borderSide: const BorderSide(color: kAccentColor),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.surfaceAlt),
      ),
    ),
    // v1.49.5: snackBarTheme removed — feedback now uses the subtle
    // centered message dialog (see ui/widgets/app_message.dart) instead of
    // SnackBars.
  );
}

ThemeData buildDarkTheme() => _baseTheme(Brightness.dark);

ThemeData buildLightTheme() => _baseTheme(Brightness.light);

/// Code-drawn brand mark used in the app bar and drawer: a rounded square
/// with the blue gradient and a white "N" glyph — no asset involved.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: kBrandGradient,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      alignment: Alignment.center,
      child: Text(
        'N',
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.55,
          height: 1.05,
        ),
      ),
    );
  }
}
