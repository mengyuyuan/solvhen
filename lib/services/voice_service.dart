// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 语音服务调度——TTS播放队列管理、语音输入触发、火山引擎/Edge引擎路由
// ═══════════════════════════════════════════════════════════════

library;


import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'edge_tts.dart';
import 'volcano_tts.dart';
import '../models/voice_profile.dart';
import 'database_service.dart';

/// 语音服务调度器——单例
/// 职责：TTS播放队列管理 / 语音输入触发 / 引擎路由（火山/Edge/系统）
/// ⚠️ TTS仅在语音输入时播放，文字输入静默
class VoiceService {
  static final VoiceService _instance = VoiceService._();
  factory VoiceService() => _instance;
  VoiceService._();

  final VolcanoTTS _volcanoTts = VolcanoTTS();
  final EdgeTtsService _edgeTts = EdgeTtsService();
  final FlutterTts _sysTts = FlutterTts();
  final AudioPlayer _player = AudioPlayer();

  VoiceProfile? _currentProfile;
  bool _initialized = false;
  bool _speaking = false;
  bool _edgeAvailable = false;
  bool _volcanoAvailable = false;

  bool get ttsReady => _currentProfile != null;
  bool get isSpeaking => _speaking;
  bool get volcanoReady => _volcanoAvailable;

  Future<void> init() async {
    if (_initialized) return;

    // Init system TTS first as ultimate fallback
    await _sysTts.setLanguage('zh-CN');
    await _sysTts.setSpeechRate(0.45);
    await _sysTts.setPitch(1.0);

    // Try Volcano Engine (primary — best quality)
    try {
      _volcanoAvailable = await _volcanoTts.init();
      debugPrint('[VoiceService] Volcano TTS: ${_volcanoAvailable ? "available" : "unconfigured"}');
    } catch (_) {
      _volcanoAvailable = false;
    }

    // Try Edge TTS (secondary)
    if (!_volcanoAvailable) {
      try {
        final bytes = await _edgeTts.synthesize('你好');
        _edgeAvailable = bytes != null && bytes.length > 100;
        debugPrint('[VoiceService] Edge TTS: ${_edgeAvailable ? "available" : "unavailable"}');
      } catch (_) {
        _edgeAvailable = false;
        debugPrint('[VoiceService] Edge TTS failed, using system TTS');
      }
    }

    // Load profile
    final rows = await DB.getVoiceProfiles();
    VoiceProfile? active;
    for (final r in rows) {
      final p = VoiceProfile.fromMap(r);
      if (p.active == 1) active = p;
    }
    if (active != null) {
      _currentProfile = active;
    } else if (rows.isNotEmpty) {
      _currentProfile = VoiceProfile.fromMap(rows.first);
    } else {
      await _seedDefaults();
      final seeded = await DB.getVoiceProfiles();
      _currentProfile = VoiceProfile.fromMap(seeded.first);
    }
    _applyProfile(_currentProfile!);
    _initialized = true;

    final engine = _volcanoAvailable ? 'Volcano' : (_edgeAvailable ? 'Edge' : 'System');
    debugPrint('[VoiceService] Ready. Engine: $engine');
  }

  void _applyProfile(VoiceProfile p) {
    _edgeTts.setVoice(p.voiceId);
    _edgeTts.setRate(p.rate);
    _edgeTts.setPitch(p.pitch);
    _edgeTts.setVolume(p.volume);
  }

  /// Get current speaker ID — used by AI tools to report active voice.
  String get currentSpeakerId => _currentProfile?.voiceId ?? 'BV001_streaming';

  Future<void> speak(String text) async {
    if (_currentProfile == null) await init();
    if (text.trim().isEmpty) return;
    _speaking = true;
    try {
      final sentences = _splitSentences(text);
      for (final s in sentences) {
        if (!_speaking) break;
        await _speakOne(s);
      }
    } finally {
      _speaking = false;
    }
  }

  Future<void> speakChunk(String sentence) async {
    if (_currentProfile == null) return;
    _speaking = true;
    try {
      await _speakOne(sentence);
    } finally {
      _speaking = false;
    }
  }

  Future<void> _speakOne(String text) async {
    // 1. Volcano Engine (primary — human-like, China-accessible)
    if (_volcanoAvailable) {
      try {
        final bytes = await _volcanoTts.synthesize(
          text,
          speaker: _currentProfile?.voiceId ?? 'BV001_streaming',
          speed: (_currentProfile?.rate ?? 1.0).clamp(0.5, 2.0),
          pitch: (_currentProfile?.pitch ?? 0.0) + 1.0, // profile pitch is -0.5..0.5, API needs 0.5..2.0
          volume: _currentProfile?.volume ?? 1.0,
        );
        if (bytes != null && bytes.length > 100) {
          final dir = await getTemporaryDirectory();
          final file = File('${dir.path}/tts_v_${DateTime.now().millisecondsSinceEpoch}.mp3');
          await file.writeAsBytes(bytes);
          await _player.play(DeviceFileSource(file.path));
          await _player.onPlayerComplete.first;
          try { await file.delete(); } catch (_) {}
          return;
        }
      } catch (_) {}
    }

    // 2. Edge TTS (secondary)
    if (_edgeAvailable) {
      try {
        final bytes = await _edgeTts.synthesize(text);
        if (bytes != null && bytes.length > 100) {
          final dir = await getTemporaryDirectory();
          final file = File('${dir.path}/tts_${DateTime.now().millisecondsSinceEpoch}.mp3');
          await file.writeAsBytes(bytes);
          await _player.play(DeviceFileSource(file.path));
          await _player.onPlayerComplete.first;
          try { await file.delete(); } catch (_) {}
          return;
        }
      } catch (_) {}
    }

    // 3. System TTS (ultimate fallback)
    try {
      await _sysTts.speak(text);
      final ms = (text.length * 60).clamp(500, 10000);
      await Future.delayed(Duration(milliseconds: ms));
    } catch (_) {}
  }

  Future<void> stop() async {
    _speaking = false;
    try { await _player.stop(); } catch (_) {}
    try { await _sysTts.stop(); } catch (_) {}
  }

  VoiceProfile? get currentProfile => _currentProfile;

  Future<List<VoiceProfile>> getProfiles() async {
    final rows = await DB.getVoiceProfiles();
    return rows.map((r) => VoiceProfile.fromMap(r)).toList();
  }

  Future<void> setProfile(VoiceProfile profile) async {
    _currentProfile = profile;
    _applyProfile(profile);
    await DB.activateVoiceProfile(profile.id);
  }

  Future<VoiceProfile> createProfile({
    required String name,
    String voiceId = 'BV001_streaming',
    double pitch = 0.0, double rate = 1.0, double volume = 1.0,
  }) async {
    await DB.createVoiceProfile(
      name: name, voiceId: voiceId, pitch: pitch, rate: rate, volume: volume, locale: 'zh-CN',
    );
    final rows = await DB.getVoiceProfiles();
    return VoiceProfile.fromMap(rows.last);
  }

  Future<void> deleteProfile(int id) => DB.deleteVoiceProfile(id);

  List<String> _splitSentences(String text) {
    final result = <String>[];
    final buf = StringBuffer();
    for (int i = 0; i < text.length; i++) {
      buf.write(text[i]);
      if (text[i] == '。' || text[i] == '！' || text[i] == '？' || text[i] == '\n') {
        final s = buf.toString().trim();
        if (s.isNotEmpty && s.length > 1) result.add(s);
        buf.clear();
      }
    }
    final remaining = buf.toString().trim();
    if (remaining.isNotEmpty && remaining.length > 1) result.add(remaining);
    return result;
  }

  Future<void> _seedDefaults() async {
    final now = DateTime.now();
    // Use Volcano voices as defaults when available
    final defaults = _volcanoAvailable
        ? [
            ('梓欣·清新女声', 'BV001_streaming', 0.0, 1.0, 1.0),
            ('梓炀·沉稳男声', 'BV002_streaming', 0.0, 1.0, 1.0),
            ('梓萌·温柔知性', 'BV003_streaming', 0.0, 1.0, 1.0),
          ]
        : VoiceProfile.defaultProfiles;
    for (final (name, voiceId, pitch, rate, vol) in defaults) {
      await DB.createVoiceProfile(
        name: name, voiceId: voiceId, pitch: pitch, rate: rate, volume: vol, locale: 'zh-CN',
        createdAt: now,
      );
    }
  }
}
