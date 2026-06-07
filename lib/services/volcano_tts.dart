// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 火山引擎TTS实现——流式语音合成，支持克隆音色+22种预置音色
// ═══════════════════════════════════════════════════════════════

library;

/// Free tier: 1M chars/month. 21+ voices, controllable pitch/speed/volume.
/// Auth: App ID + Token from https://console.volcengine.com/speech

import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import '../services/database_service.dart';

/// 火山引擎流式TTS——22+预置音色 + 克隆音色支持
/// 免费额度：100万字符/月
class VolcanoTTS {
  static const _endpoint = 'https://openspeech.bytedance.com/api/v1/tts';
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 15),
  ));

  String? _appId;
  String? _token;
  bool _loaded = false;

  /// All available Volcano voice types with descriptions.
  /// Speaker IDs from Volcano Engine console — Voice Reproducing service.
  static const voices = <String, String>{
    // Standard female voices
    'zh_female_qingxin': '清新女声 — 自然活泼',
    'zh_female_shuangkuai': '爽快女声 — 干脆利落',
    'zh_female_tianmei': '甜美女声 — 温柔可爱',
    'zh_female_wenrou': '温柔女声 — 柔和细腻',
    'zh_female_zhixing': '知性女声 — 成熟稳重',
    'zh_female_gufeng': '古风女声 — 古典韵味',
    // Standard male voices
    'zh_male_chunhou': '醇厚男声 — 深沉稳重',
    'zh_male_qingse': '青涩男声 — 年轻清爽',
    'zh_male_jingying': '精英男声 — 商务干练',
    // Doubao (豆包) big-model voices — most natural
    'BV001_streaming': '豆包女声·梓欣 — 最自然女声⭐',
    'BV002_streaming': '豆包男声·梓炀 — 最自然男声⭐',
    'BV003_streaming': '豆包女声·梓萌 — 温柔知性',
    'BV004_streaming': '豆包女声·梓涵 — 活泼元气',
    'BV005_streaming': '豆包男声·梓轩 — 沉稳大气',
    'BV006_streaming': '豆包女声·梓瑶 — 甜美撒娇',
    'BV007_streaming': '豆包男声·梓豪 — 阳光开朗',
    // Emotional / conversational
    'zh_female_vv_uranus': '情感女声·乌拉诺斯 — 多情绪表达',
    'zh_male_vv_mars': '情感男声·马尔斯 — 多情绪表达',
    // Dialect / special
    'zh_female_sichuan': '四川话女声',
    'zh_male_sichuan': '四川话男声',
    'zh_female_cantonese': '粤语女声',
  };

  /// Load credentials from DB config.
  Future<bool> init() async {
    if (_loaded) return _appId != null && _token != null;
    try {
      final cfg = await DB.getConfig();
      final appId = cfg['volcano_app_id'];
      final token = cfg['volcano_token'];
      _loaded = true;
      return _appId != null && _appId!.isNotEmpty &&
             _token != null && _token!.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Check if configured.
  bool get isAvailable => _appId != null && _appId!.isNotEmpty &&
                           _token != null && _token!.isNotEmpty;

  /// Synthesize text to MP3 bytes.
  /// [speaker] — voice ID from [voices] keys (default: BV001_streaming)
  /// [speed] — 0.5 ~ 2.0 (default: 1.0)
  /// [pitch] — 0.5 ~ 2.0 (default: 1.0)
  /// [volume] — 0.1 ~ 3.0 (default: 1.0)
  Future<List<int>?> synthesize(
    String text, {
    String speaker = 'BV001_streaming',
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
  }) async {
    if (!isAvailable) await init();
    if (!isAvailable) return null;

    final body = {
      'app': {
        'appid': _appId,
        'token': _token,
        'cluster': 'volcano_tts',
      },
      'user': {'uid': 'solvhen'},
      'audio': {
        'voice_type': speaker,
        'encoding': 'mp3',
        'speed_ratio': speed.clamp(0.5, 2.0),
        'pitch_ratio': pitch.clamp(0.5, 2.0),
        'volume_ratio': volume.clamp(0.1, 3.0),
      },
      'request': {
        'reqid': 'solvhen_${_randomId()}',
        'text': text,
        'text_type': 'plain',
        'operation': 'query',
      },
    };

    try {
      final resp = await _dio.post(
        _endpoint,
        data: jsonEncode(body),
        options: Options(
          headers: {
            'Authorization': 'Bearer;$_token',
            'Content-Type': 'application/json',
          },
          responseType: ResponseType.bytes,
        ),
      );

      if (resp.statusCode == 200 && resp.data is List<int>) {
        final bytes = resp.data as List<int>;
        if (bytes.length > 100) return bytes;
      }
      return null;
    } on DioException {
      return null;
    } catch (_) {
      return null;
    }
  }

  String _randomId() {
    final r = Random();
    return '${DateTime.now().millisecondsSinceEpoch}_${r.nextInt(9999)}';
  }
}
