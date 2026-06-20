import 'package:flutter/material.dart';

class YurichColors {
  const YurichColors._();

  static const background = Color(0xFF03101C);
  static const backgroundMid = Color(0xFF061827);
  static const backgroundDeep = Color(0xFF071D2E);

  static const surface = Color(0xB80A2030);
  static const surfaceSolid = Color(0xFF0D1A27);
  static const surfaceMetric = Color(0xFF10283B);
  static const surfaceElevated = Color(0xFF0A2132);

  static const border = Color(0x403CA0D2);
  static const borderStrong = Color(0x9929E6F6);
  static const accentCyan = Color(0xFF29E6F6);
  static const accentBlue = Color(0xFF1688C7);
  static const accentSoft = Color(0xFFEAF7FF);

  static const textPrimary = Color(0xFFF2F6FA);
  static const textSecondary = Color(0xFF9CAFC1);
  static const textMuted = Color(0xFF6F8193);

  static const success = Color(0xFF4DE59B);
  static const warning = Color(0xFFFFC857);
  static const danger = Color(0xFFFF5C7A);
  static const dangerSoft = Color(0xFFFFD7DF);
  static const shadow = Color(0x99000000);
}

class YurichRadii {
  const YurichRadii._();

  static const double card = 24;
  static const double panel = 20;
  static const double control = 16;
  static const double chip = 14;
}

class YurichGradients {
  const YurichGradients._();

  static const background = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      YurichColors.background,
      YurichColors.backgroundMid,
      YurichColors.backgroundDeep,
    ],
  );

  static const header = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF071A2A), Color(0xFF0B2B40), YurichColors.background],
  );

  static const activeCard = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF0B2B40), Color(0xFF0E3A56), YurichColors.surfaceSolid],
  );

  static const inactiveCard = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [YurichColors.surfaceSolid, Color(0xFF0A1B29)],
  );

  static const centerPanel = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [YurichColors.surfaceSolid, Color(0xFF081D2C), Color(0xFF071522)],
  );

  static const compactCard = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF09283D), Color(0xFF071C2C), YurichColors.background],
  );

  static const selectedProfile = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF0E4A68), Color(0xFF0A2C42), YurichColors.backgroundDeep],
  );

  static const activeBadge = LinearGradient(
    colors: [Color(0xFF67E8F9), YurichColors.accentBlue],
  );

  static const errorCard = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF2A111B), Color(0xFF411623), YurichColors.surfaceSolid],
  );

  static const metric = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [YurichColors.surfaceMetric, Color(0xFF0C3148)],
  );

  static const cyanButton = RadialGradient(
    colors: [
      YurichColors.accentSoft,
      Color(0xFF67E8F9),
      YurichColors.accentCyan,
    ],
  );

  static const idleButton = RadialGradient(
    colors: [YurichColors.surfaceMetric, YurichColors.surfaceSolid],
  );

  static const dangerButton = RadialGradient(
    colors: [YurichColors.dangerSoft, Color(0xFFFF6B81), YurichColors.danger],
  );
}

class YurichTheme {
  const YurichTheme._();

  static ThemeData dark() {
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: YurichColors.accentCyan,
          brightness: Brightness.dark,
        ).copyWith(
          primary: YurichColors.accentCyan,
          secondary: YurichColors.accentBlue,
          error: YurichColors.danger,
          surface: YurichColors.surfaceSolid,
          onSurface: YurichColors.textPrimary,
        );

    final baseTextTheme = Typography.whiteMountainView.apply(
      bodyColor: YurichColors.textPrimary,
      displayColor: YurichColors.textPrimary,
    );

    return ThemeData(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: YurichColors.background,
      useMaterial3: true,
      textTheme: baseTextTheme.copyWith(
        titleLarge: baseTextTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
        titleMedium: baseTextTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
        titleSmall: baseTextTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
        bodyMedium: baseTextTheme.bodyMedium?.copyWith(letterSpacing: 0),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: YurichColors.textPrimary,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: YurichColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YurichRadii.panel),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: YurichColors.accentCyan,
          foregroundColor: YurichColors.background,
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(YurichRadii.control),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: YurichColors.accentSoft,
          side: const BorderSide(color: YurichColors.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(YurichRadii.control),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: YurichColors.surfaceMetric,
        selectedColor: YurichColors.accentCyan,
        disabledColor: YurichColors.surfaceSolid,
        labelStyle: const TextStyle(color: YurichColors.accentSoft),
        secondaryLabelStyle: const TextStyle(color: YurichColors.background),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YurichRadii.chip),
          side: const BorderSide(color: YurichColors.border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: YurichColors.surfaceMetric,
        hintStyle: const TextStyle(color: YurichColors.textSecondary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(YurichRadii.control),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(YurichRadii.control),
          borderSide: const BorderSide(color: YurichColors.accentCyan),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: YurichColors.surfaceSolid,
        contentTextStyle: const TextStyle(
          color: YurichColors.textPrimary,
          height: 1.35,
        ),
        actionTextColor: YurichColors.accentCyan,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YurichRadii.control),
        ),
      ),
      expansionTileTheme: const ExpansionTileThemeData(
        collapsedIconColor: YurichColors.textSecondary,
        iconColor: YurichColors.accentSoft,
        collapsedTextColor: YurichColors.textPrimary,
        textColor: YurichColors.textPrimary,
      ),
    );
  }
}
