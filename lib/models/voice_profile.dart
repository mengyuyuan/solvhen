/// Voice profile — configurable Edge TTS voice settings.
class VoiceProfile {
  final int? id;
  final String name;
  final String voiceId;   // Edge TTS voice ID (e.g. zh-CN-XiaoxiaoNeural)
  final double pitch;     // -0.5 to 0.5
  final double rate;      // 0.5 to 2.0
  final double volume;    // 0.0 to 1.0
  final String locale;    // zh-CN
  final int active;
  final DateTime createdAt;

  const VoiceProfile({
    this.id,
    required this.name,
    this.voiceId = 'zh-CN-XiaoxiaoNeural',
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
    voiceId: (m['voice_id'] as String?) ?? 'zh-CN-XiaoxiaoNeural',
    pitch: (m['pitch'] as num?)?.toDouble() ?? 0.0,
    rate: (m['rate'] as num?)?.toDouble() ?? 1.0,
    volume: (m['volume'] as num?)?.toDouble() ?? 1.0,
    locale: m['locale'] as String? ?? 'zh-CN',
    active: (m['active'] as int?) ?? 0,
    createdAt: DateTime.parse(m['created_at'] as String),
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

  /// Edge TTS defaults — real neural voices.
  static const defaultProfiles = [
    ('温柔小小', 'zh-CN-XiaoxiaoNeural', 0.0, 1.0, 1.0),
    ('磁性云希', 'zh-CN-YunxiNeural', -0.05, 0.95, 1.0),
    ('活泼小艺', 'zh-CN-XiaoyiNeural', 0.05, 1.1, 1.0),
    ('稳重云浩', 'zh-CN-YunhaoNeural', -0.1, 0.9, 1.0),
  ];
}
