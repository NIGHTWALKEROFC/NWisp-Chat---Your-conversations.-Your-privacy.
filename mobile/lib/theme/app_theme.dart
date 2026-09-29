import 'package:flutter/material.dart';

/// Central place for the app's visual identity.
///
/// Redesigned 2026-09-29 to match the new NWisp design sheet: deep navy
/// surfaces, a vivid blue -> violet accent, thin blue-tinted borders on
/// cards and rounded (16-20px) shapes everywhere.
///
/// [seedColor] can still be overridden per-device from Settings >
/// Appearance. Everything else (surfaces, borders) stays navy so the app
/// keeps its look whichever accent is picked.
class AppTheme {
  /// Signature accent — the blue of the NWisp "N" logo.
  static const Color defaultSeedColor = Color(0xFF4C7DFF);

  /// Second stop of the brand gradient (violet). Used with the accent for
  /// gradient buttons, story rings, the logo and so on.
  static const Color brandViolet = Color(0xFF7B5CFF);

  // Navy surface ladder (dark mode), darkest -> lightest.
  static const Color darkSurface = Color(0xFF070B1A);
  static const Color darkSurfaceLow = Color(0xFF0A1024);
  static const Color darkSurfaceMid = Color(0xFF0E1530);
  static const Color darkSurfaceHigh = Color(0xFF131B3A);
  static const Color darkSurfaceHighest = Color(0xFF1A2347);
  static const Color darkBorder = Color(0xFF26315E);

  /// The two-colour gradient used for primary buttons, rings, logo.
  static LinearGradient brandGradient([Color? accent]) {
    final a = accent ?? defaultSeedColor;
    return LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [a, Color.lerp(a, brandViolet, 0.75)!],
    );
  }

  static ThemeData light([Color? seedColor]) {
    final seed = seedColor ?? defaultSeedColor;
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
    ).copyWith(
      primary: seed,
      onPrimary: _onColor(seed),
      surface: const Color(0xFFF6F8FE),
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFF1F4FC),
      surfaceContainer: const Color(0xFFECF0FA),
      surfaceContainerHigh: Colors.white,
      surfaceContainerHighest: const Color(0xFFE3E9F7),
      outlineVariant: const Color(0xFFD5DDF2),
    );
    return _base(scheme);
  }

  static ThemeData dark([Color? seedColor]) {
    final seed = seedColor ?? defaultSeedColor;
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    ).copyWith(
      // Use the accent itself (not Material's pastel tone of it) so buttons
      // and sent bubbles are vivid like in the design.
      primary: seed,
      onPrimary: _onColor(seed),
      primaryContainer: Color.lerp(darkSurfaceHigh, seed, 0.28),
      onPrimaryContainer: Colors.white,
      surface: darkSurface,
      onSurface: const Color(0xFFEAF0FF),
      onSurfaceVariant: const Color(0xFF9AA6C9),
      surfaceContainerLowest: const Color(0xFF050815),
      surfaceContainerLow: darkSurfaceLow,
      surfaceContainer: darkSurfaceMid,
      surfaceContainerHigh: darkSurfaceHigh,
      surfaceContainerHighest: darkSurfaceHighest,
      outline: const Color(0xFF3A4675),
      outlineVariant: darkBorder,
    );
    return _base(scheme);
  }

  static Color _onColor(Color c) => c.computeLuminance() > 0.6 ? Colors.black : Colors.white;

  static ThemeData _base(ColorScheme scheme) {
    final isDark = scheme.brightness == Brightness.dark;
    // Tinted shadow — blended toward the primary instead of plain black.
    final tintedShadow = Color.lerp(Colors.black, scheme.primary, 0.15)!;
    final cardBorder = BorderSide(color: scheme.outlineVariant.withValues(alpha: isDark ? 0.7 : 1), width: 1);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      shadowColor: tintedShadow,
      dividerColor: scheme.outlineVariant.withValues(alpha: 0.5),

      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        shadowColor: tintedShadow,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
      ),

      textTheme: const TextTheme(
        headlineSmall: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.3),
        titleLarge: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.2),
        titleMedium: TextStyle(fontWeight: FontWeight.w600),
        titleSmall: TextStyle(fontWeight: FontWeight.w600),
        bodyMedium: TextStyle(fontSize: 15, height: 1.4),
        labelLarge: TextStyle(fontWeight: FontWeight.w600),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? darkSurfaceHigh.withValues(alpha: 0.9) : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.error, width: 1.2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.error, width: 1.6),
        ),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          elevation: 0,
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          minimumSize: const Size(64, 50),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          side: BorderSide(color: scheme.outlineVariant),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
      ),

      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          side: BorderSide(color: scheme.outlineVariant),
          backgroundColor: isDark ? darkSurfaceMid : null,
          selectedBackgroundColor: scheme.primary.withValues(alpha: 0.22),
          selectedForegroundColor: isDark ? Colors.white : scheme.primary,
        ),
      ),

      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
        ),
      ),

      cardTheme: CardThemeData(
        color: scheme.surfaceContainerHigh,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shadowColor: tintedShadow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: cardBorder),
        margin: EdgeInsets.zero,
      ),

      listTileTheme: ListTileThemeData(
        iconColor: scheme.primary,
        textColor: scheme.onSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? Colors.white : scheme.onSurfaceVariant,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? scheme.primary : scheme.surfaceContainerHighest,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? Colors.transparent : scheme.outlineVariant,
        ),
      ),

      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? scheme.primary : null,
        ),
      ),

      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        circularTrackColor: scheme.surfaceContainerHighest,
        linearTrackColor: scheme.surfaceContainerHighest,
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 4,
        highlightElevation: 6,
        shape: const CircleBorder(),
      ),

      // Bottom bar — the design uses a slightly lighter navy strip with a
      // soft blue pill behind the selected item.
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? darkSurfaceLow : scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 68,
        indicatorColor: scheme.primary.withValues(alpha: isDark ? 0.22 : 0.14),
        indicatorShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 24,
            color: selected ? (isDark ? Colors.white : scheme.primary) : scheme.onSurfaceVariant,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 11.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? (isDark ? Colors.white : scheme.primary) : scheme.onSurfaceVariant,
          );
        }),
      ),

      tabBarTheme: TabBarThemeData(
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        labelStyle: const TextStyle(fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500),
        indicatorSize: TabBarIndicatorSize.label,
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: scheme.primary, width: 3),
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(3), topRight: Radius.circular(3)),
        ),
      ),

      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shadowColor: tintedShadow,
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: cardBorder),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark ? darkSurfaceLow : scheme.surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: tintedShadow,
        elevation: 3,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        dragHandleColor: scheme.onSurfaceVariant.withValues(alpha: 0.4),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shadowColor: tintedShadow,
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: cardBorder),
        titleTextStyle: TextStyle(color: scheme.onSurface, fontSize: 18, fontWeight: FontWeight.w700),
        contentTextStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14.5, height: 1.4),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.primary.withValues(alpha: 0.22),
        labelStyle: TextStyle(color: scheme.onSurface, fontSize: 13, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),

      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.5),
        space: 1,
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? darkSurfaceHighest : scheme.inverseSurface,
        contentTextStyle: TextStyle(color: isDark ? scheme.onSurface : scheme.onInverseSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actionTextColor: isDark ? scheme.primary : scheme.inversePrimary,
      ),

      badgeTheme: BadgeThemeData(
        backgroundColor: scheme.primary,
        textColor: scheme.onPrimary,
      ),
    );
  }
}
