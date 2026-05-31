/// Loads base personality text from asset .md files.
/// Replaces hardcoded _baseIdentity/_baseVoice/_baseConstraints in prompt_builder.dart.
///
/// Three files in assets/personality/:
///   base-identity.md   — who Solvhen is
///   base-voice.md      — how Solvhen speaks
///   base-constraints.md — rules and habits
///
/// Cached after first load to avoid repeated asset reads.
library;

import 'package:flutter/services.dart' show rootBundle;

class PersonalityLoader {
  static String? _identity;
  static String? _voice;
  static String? _constraints;

  static Future<String> loadIdentity() async {
    _identity ??= await rootBundle.loadString('assets/personality/base-identity.md');
    return _identity!;
  }

  static Future<String> loadVoice() async {
    _voice ??= await rootBundle.loadString('assets/personality/base-voice.md');
    return _voice!;
  }

  static Future<String> loadConstraints() async {
    _constraints ??= await rootBundle.loadString('assets/personality/base-constraints.md');
    return _constraints!;
  }
}
