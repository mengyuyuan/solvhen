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
    if (_identity != null) return _identity!;
    try {
      _identity = await rootBundle.loadString('assets/personality/base-identity.md');
    } catch (e) {
      _identity = '你是 Solvhen，一个 AI 手机助手。';
    }
    return _identity!;
  }

  static Future<String> loadVoice() async {
    if (_voice != null) return _voice!;
    try {
      _voice = await rootBundle.loadString('assets/personality/base-voice.md');
    } catch (e) {
      _voice = '用自然、友好的语气回复。';
    }
    return _voice!;
  }

  static Future<String> loadConstraints() async {
    if (_constraints != null) return _constraints!;
    try {
      _constraints = await rootBundle.loadString('assets/personality/base-constraints.md');
    } catch (e) {
      _constraints = '保持诚实和有用。';
    }
    return _constraints!;
  }
}
