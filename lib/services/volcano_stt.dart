// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 火山引擎语音识别——实时流式STT，将语音转为文本
// ═══════════════════════════════════════════════════════════════

library;

/// Free tier: shared with TTS quota. Superior Chinese recognition vs Google STT.
/// Falls back gracefully when not configured.

import 'dart:io';
import 'package:dio/dio.dart';
import '../services/database_service.dart';

/// 火山引擎语音识别——流式实时STT，将语音转为文本
class VolcanoSTT {
  static const _endpoint = 'https://openspeech.bytedance.com/api/v1/asr';
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 20),
  ));

  String? _appId;
  String? _token;
  bool _loaded = false;

  Future<bool> init() async {
    if (_loaded) return _appId != null && _token != null;
    try {
      final cfg = await DB.getConfig();
      _appId = cfg['volcano_app_id'];
      _token = cfg['volcano_token'];
      _loaded = true;
      return _appId != null && _appId!.isNotEmpty &&
             _token != null && _token!.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  bool get isAvailable => _appId != null && _appId!.isNotEmpty &&
                           _token != null && _token!.isNotEmpty;

  /// Recognize speech from audio file (WAV/PCM/MP3).
  /// Returns recognized text, or null on failure.
  Future<String?> recognize(File audioFile) async {
    if (!isAvailable) await init();
    if (!isAvailable) return null;

    try {
      final bytes = await audioFile.readAsBytes();
      final formData = FormData.fromMap({
        'appid': _appId!,
        'token': _token!,
        'cluster': 'volcengine_input_common',
        'audio': MultipartFile.fromBytes(bytes, filename: 'audio.wav'),
      });

      final resp = await _dio.post(
        _endpoint,
        data: formData,
        options: Options(
          headers: {'Authorization': 'Bearer;$_token'},
        ),
      );

      if (resp.statusCode == 200 && resp.data is Map) {
        final result = resp.data['result'] as Map<String, dynamic>?;
        final text = result?['text'] as String?;
        if (text != null && text.isNotEmpty) return text;
      }
      return null;
    } on DioException {
      return null;
    } catch (_) {
      return null;
    }
  }
}
