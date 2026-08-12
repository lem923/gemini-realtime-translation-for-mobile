import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../conversation/conversation_controller.dart';
import '../permissions/microphone_permission_gateway.dart';
import '../preferences/language_pair_store.dart';
import '../ui/conversation_page.dart';

class RealtimeTranslationApp extends StatefulWidget {
  const RealtimeTranslationApp({super.key});

  @override
  State<RealtimeTranslationApp> createState() => _RealtimeTranslationAppState();
}

class _RealtimeTranslationAppState extends State<RealtimeTranslationApp> {
  late final ConversationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ConversationController(
      languagePairStore: SharedPreferencesLanguagePairStore(),
      permissionGateway: const PlatformMicrophonePermissionGateway(),
    );
    unawaited(_controller.initialize());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const Color seed = Color(0xFF006B68);
    final ColorScheme lightScheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
    );
    final ColorScheme darkScheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: '即时翻译',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const <Locale>[Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      themeMode: ThemeMode.system,
      theme: _theme(lightScheme),
      darkTheme: _theme(darkScheme),
      home: ConversationPage(controller: _controller),
    );
  }

  ThemeData _theme(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
    );
  }
}
