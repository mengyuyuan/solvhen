// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 语音配置模型——可配置的TTS音色设置，含音调/语速/音量/地区
// ═══════════════════════════════════════════════════════════════

library;

/// 语音配置文件——TTS音色+参数组合
/// [voiceId] 火山引擎音色ID(如BV001_streaming)或Edge语音ID
/// [pitch] 音调 -0.5~0.5 [rate] 语速 0.5~2.0 [volume] 音量 0.0~1.0
class VoiceProfile {
  final int? id;
  final String name;
  final String voiceId;   // Volcano speaker ID (e.g. BV001_streaming) or Edge voice ID
  final double pitch;     // -0.5 to 0.5 (mapped to API range)
  final double rate;      // 0.5 to 2.0
  final double volume;    // 0.0 to 1.0
  final String locale;    // zh-CN
  final int active;
  final DateTime createdAt;

  const VoiceProfile({
    this.id,
    required this.name,
    this.voiceId = 'BV001_streaming',
    this.pitch = 0.0,
    this.rate = 1.0,
    this.volume = 1.0,
    this.locale = 'zh-CN',
    this.active = 0,
    required this.createdAt,
  });

  factory VoiceProfile.fromMap(Map<String, dynamic> m) => VoiceProfile(
    id: m['id'] as int?,
    name: m['name'] as String,
    voiceId: (m['voice_id'] as String?) ?? 'BV001_streaming',
    pitch: (m['pitch'] as num?)?.toDouble() ?? 0.0,
    rate: (m['rate'] as num?)?.toDouble() ?? 1.0,
    volume: (m['volume'] as num?)?.toDouble() ?? 1.0,
    locale: m['locale'] as String? ?? 'zh-CN',
    active: (m['active'] as int?) ?? 0,
    createdAt: m['created_at'] != null ? DateTime.parse(m['created_at'] as String) : DateTime.now(),
  );

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'name': name,
    'voice_id': voiceId,
    'pitch': pitch,
    'rate': rate,
    'volume': volume,
    'locale': locale,
    'active': active,
    'created_at': createdAt.toIso8601String(),
  };

  VoiceProfile copyWith({
    int? id, String? name, String? voiceId,
    double? pitch, double? rate, double? volume,
    String? locale, int? active, DateTime? createdAt,
  }) => VoiceProfile(
    id: id ?? this.id, name: name ?? this.name,
    voiceId: voiceId ?? this.voiceId,
    pitch: pitch ?? this.pitch, rate: rate ?? this.rate,
    volume: volume ?? this.volume, locale: locale ?? this.locale,
    active: active ?? this.active, createdAt: createdAt ?? this.createdAt,
  );

  /// Default profiles — Volcano voices (primary) + Edge TTS fallbacks.
  static const defaultProfiles = [
    ('梓欣·清新女声', 'BV001_streaming', 0.0, 1.0, 1.0),
    ('梓炀·沉稳男声', 'BV002_streaming', 0.0, 1.0, 1.0),
    ('梓萌·温柔知性', 'BV003_streaming', 0.0, 1.0, 1.0),
    ('小小·Edge备选', 'zh-CN-XiaoxiaoNeural', 0.0, 1.0, 1.0),
  ];
}
