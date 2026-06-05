/// VoiceService — dual-engine TTS: Edge TTS (primary) + system TTS (fallback).
library;

import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'edge_tts.dart';
import '../models/voice_profile.dart';
import 'database_service.dart';

class VoiceService {
  static final VoiceService _instance = VoiceService._();
  factory VoiceService() => _instance;
  VoiceService._();

  final EdgeTtsService _edgeTts = EdgeTtsService();
  final FlutterTts _sysTts = FlutterTts();
  final AudioPlayer _player = AudioPlayer();

  VoiceProfile? _currentProfile;
  bool _initialized = false;
  bool _speaking = false;
  bool _edgeAvailable = false;

  static const voices = EdgeTtsService.voices;

  bool get ttsReady => _currentProfile != null;
  bool get isSpeaking => _speaking;

  Future<void> init() async {
    if (_initialized) return;

    // Init system TTS first as fallback
    await _sysTts.setLanguage('zh-CN');
    await _sysTts.setSpeechRate(0.45);
    await _sysTts.setPitch(1.0);

    // Try Edge TTS
    try {
      final bytes = await _edgeTts.synthesize('你好');
      _edgeAvailable = bytes != null && bytes.length > 100;
      debugPrint('[VoiceService] Edge TTS: ${_edgeAvailable ? "available" : "unavailable"}');
    } catch (_) {
      _edgeAvailable = false;
      debugPrint('[VoiceService] Edge TTS failed, using system TTS');
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

    debugPrint('[VoiceService] Ready. Engine: ${_edgeAvailable ? "Edge" : "System"}');
  }

  void _applyProfile(VoiceProfile p) {
    _edgeTts.setVoice(p.voiceId);
    _edgeTts.setRate(p.rate);
    _edgeTts.setPitch(p.pitch);
    _edgeTts.setVolume(p.volume);
  }

  Future<void> speak(String text) async {
    if (_currentProfile == null) await init();
    if (text.trim().isEmpty) return;
    _speaking = true;

    final sentences = _splitSentences(text);
    for (final s in sentences) {
      if (!_speaking) break;
      await _speakOne(s);
    }
    _speaking = false;
  }

  Future<void> speakChunk(String sentence) async {
    if (_currentProfile == null) return;
    _speaking = true;
    await _speakOne(sentence);
    _speaking = false;
  }

  Future<void> _speakOne(String text) async {
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

    // Fallback to system TTS
    try {
      await _sysTts.speak(text);
      // flutter_tts speak is async but doesn't wait — estimate duration
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
    String voiceId = 'zh-CN-XiaoxiaoNeural',
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
    for (final (name, voiceId, pitch, rate, vol) in VoiceProfile.defaultProfiles) {
      await DB.createVoiceProfile(
        name: name, voiceId: voiceId, pitch: pitch, rate: rate, volume: vol, locale: 'zh-CN',
        createdAt: now,
      );
    }
  }
}
