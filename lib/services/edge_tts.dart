// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// Edge TTS实现——微软Edge语音合成（国内网络下不可用，作为备用引擎）
// ═══════════════════════════════════════════════════════════════

library;

import 'dart:async';
import 'package:dio/dio.dart';

/// Edge TTS引擎实现——微软Edge语音合成
/// ⚠️ 国内网络不可用（speech.platform.bing.com被墙），仅作备用引擎
/// 可用音色：小小/云希/小艺/云浩/云霞/云健
class EdgeTtsService {
  static final EdgeTtsService _instance = EdgeTtsService._();
  factory EdgeTtsService() => _instance;
  EdgeTtsService._();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
  ));

  String? _token;
  DateTime _tokenExpiry = DateTime.now();

  String _voice = 'zh-CN-XiaoxiaoNeural';
  double _rate = 1.0;
  double _pitch = 0.0;
  double _volume = 1.0;

  String get voice => _voice;
  double get rate => _rate;
  double get pitch => _pitch;
  double get volume => _volume;

  static const voices = [
    {'id': 'zh-CN-XiaoxiaoNeural', 'name': '小小 (温柔女声)'},
    {'id': 'zh-CN-XiaoyiNeural', 'name': '小艺 (活泼少女)'},
    {'id': 'zh-CN-YunxiNeural', 'name': '云希 (磁性男声)'},
    {'id': 'zh-CN-YunjianNeural', 'name': '云健 (成熟男声)'},
    {'id': 'zh-CN-XiaobeiNeural', 'name': '小贝 (可爱女声)'},
    {'id': 'zh-CN-YunyangNeural', 'name': '云扬 (新闻男声)'},
    {'id': 'zh-CN-XiaoxuanNeural', 'name': '小萱 (甜美女声)'},
    {'id': 'zh-CN-XiaohanNeural', 'name': '小涵 (知性女声)'},
    {'id': 'zh-CN-YunhaoNeural', 'name': '云浩 (稳重男声)'},
    {'id': 'zh-CN-YunfengNeural', 'name': '云枫 (青年男声)'},
    {'id': 'zh-TW-HsiaoChenNeural', 'name': '小辰 (台湾女声)'},
    {'id': 'zh-HK-HiuMaanNeural', 'name': '曉曼 (香港女声)'},
    {'id': 'en-US-JennyNeural', 'name': 'Jenny (美式女声)'},
    {'id': 'en-US-GuyNeural', 'name': 'Guy (美式男声)'},
    {'id': 'en-GB-SoniaNeural', 'name': 'Sonia (英式女声)'},
    {'id': 'en-GB-RyanNeural', 'name': 'Ryan (英式男声)'},
  ];

  void setVoice(String v) => _voice = v;
  void setRate(double r) => _rate = r.clamp(0.5, 2.0);
  void setPitch(double p) => _pitch = p.clamp(-0.5, 0.5);
  void setVolume(double v) => _volume = v.clamp(0.0, 1.0);

  /// Synthesize one sentence → audio bytes (MP3).
  /// Returns null on failure.
  Future<List<int>?> synthesize(String text) async {
    try {
      final token = await _getToken();
      final ssml = _buildSSML(text);

      final resp = await _dio.post(
        'https://speech.platform.bing.com/consumer/speech/synthesize/readaloud?trustedclienttoken=$token',
        options: Options(
          headers: {
            'Content-Type': 'application/ssml+xml',
            'X-Microsoft-OutputFormat': 'audio-24khz-48kbitrate-mono-mp3',
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
            'Accept': '*/*',
          },
          responseType: ResponseType.bytes,
        ),
        data: ssml,
      );

      if (resp.data is List<int>) {
        final bytes = resp.data as List<int>;
        if (bytes.length >= 100) return bytes;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String> _getToken() async {
    if (_token != null && DateTime.now().isBefore(_tokenExpiry)) return _token!;
    final resp = await _dio.get(
      'https://edge.microsoft.com/translate/auth',
      options: Options(responseType: ResponseType.plain),
    );
    _token = resp.data.toString().trim();
    _tokenExpiry = DateTime.now().add(const Duration(minutes: 9));
    return _token!;
  }

  String _buildSSML(String text) {
    final escaped = text
        .replaceAll('&', '&amp;').replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;').replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');

    final rateStr = _rate >= 1.0
        ? '+${((_rate - 1.0) * 100).round()}%'
        : '${((_rate - 1.0) * 100).round()}%';
    final pitchStr = _pitch >= 0
        ? '+${(_pitch * 100).round()}Hz'
        : '${(_pitch * 100).round()}Hz';

    return '''<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xmlns:mstts="http://www.w3.org/2001/mstts" xml:lang="zh-CN"><voice name="$_voice"><prosody rate="$rateStr" pitch="$pitchStr" volume="${(_volume * 100).round()}">$escaped</prosody></voice></speak>''';
  }
}
