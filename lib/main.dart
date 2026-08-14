import 'package:flutter/material.dart';

import 'app/realtime_translation_app.dart';
import 'shared/crash_log.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  CrashLog.instance.installFlutterHooks();
  runApp(const RealtimeTranslationApp());
}
