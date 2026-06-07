// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// TTS提供商注册表——火山引擎/Edge/系统/GPT-SoVITS/自定义5种引擎+60+音色
// ═══════════════════════════════════════════════════════════════

library;



// ── Engine ──

class TtsEngine {
  final String id;
  final String name;
  final String? defaultUrl;
  final bool supportsCloning;
  final List<AuthField> authFields;
  final List<TtsVoice> voices;
  const TtsEngine({
    required this.id, required this.name, this.defaultUrl,
    this.supportsCloning = false, this.authFields = const [], this.voices = const [],
  });
}

class AuthField {
  final String key;
  final String label;
  final bool secret;
  const AuthField({required this.key, required this.label, this.secret = false});
}

// ── Voice ──

class TtsVoice {
  final String id;
  final String name;
  final String gender; // 'female' | 'male'
  final List<String> tags;
  const TtsVoice({required this.id, required this.name, this.gender = 'female', this.tags = const []});
}

// ── Cloned voice ──

class ClonedVoice {
  final String id;
  final String name;
  final String engineId;
  final String? voiceId;    // engine-returned clone ID
  final String? audioPath;  // local reference audio path
  const ClonedVoice({required this.id, required this.name, required this.engineId, this.voiceId, this.audioPath});

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'engineId': engineId,
    if (voiceId != null) 'voiceId': voiceId,
    if (audioPath != null) 'audioPath': audioPath,
  };
  factory ClonedVoice.fromJson(Map<String, dynamic> j) => ClonedVoice(
    id: j['id'] as String, name: j['name'] as String, engineId: j['engineId'] as String,
    voiceId: j['voiceId'] as String?, audioPath: j['audioPath'] as String?,
  );
}

// ── Full TTS config ──

class TtsConfig {
  final String engineId;
  final String voiceId;
  final double speed;
  final double pitch;
  final double volume;
  final Map<String, String> auth;
  final List<ClonedVoice> clonedVoices;

  const TtsConfig({
    this.engineId = 'volcano',
    this.voiceId = 'BV001_streaming',
    this.speed = 1.0, this.pitch = 0.0, this.volume = 1.0,
    this.auth = const {},
    this.clonedVoices = const [],
  });

  Map<String, dynamic> toJson() => {
    'engineId': engineId, 'voiceId': voiceId,
    'speed': speed, 'pitch': pitch, 'volume': volume,
    'auth': auth,
    'clonedVoices': clonedVoices.map((v) => v.toJson()).toList(),
  };
  factory TtsConfig.fromJson(Map<String, dynamic> j) => TtsConfig(
    engineId: j['engineId'] as String? ?? 'volcano',
    voiceId: j['voiceId'] as String? ?? 'BV001_streaming',
    speed: (j['speed'] as num?)?.toDouble() ?? 1.0,
    pitch: (j['pitch'] as num?)?.toDouble() ?? 0.0,
    volume: (j['volume'] as num?)?.toDouble() ?? 1.0,
    auth: (j['auth'] as Map<String, dynamic>?)?.map((k,v) => MapEntry(k, v.toString())) ?? {},
    clonedVoices: (j['clonedVoices'] as List?)?.map((e) => ClonedVoice.fromJson(e as Map<String, dynamic>)).toList() ?? [],
  );
  TtsConfig copyWith({String? engineId, String? voiceId, double? speed, double? pitch, double? volume, Map<String,String>? auth, List<ClonedVoice>? clonedVoices}) => TtsConfig(
    engineId: engineId ?? this.engineId, voiceId: voiceId ?? this.voiceId,
    speed: speed ?? this.speed, pitch: pitch ?? this.pitch, volume: volume ?? this.volume,
    auth: auth ?? this.auth, clonedVoices: clonedVoices ?? this.clonedVoices,
  );
}

// ── Pre-registered engines ──

final allTtsEngines = [
  const TtsEngine(
    id: 'volcano', name: '火山引擎', defaultUrl: 'https://openspeech.bytedance.com/api/v1/tts',
    supportsCloning: true,
    authFields: [AuthField(key: 'volcano_app_id', label: 'App ID'), AuthField(key: 'volcano_token', label: 'Token', secret: true)],
    voices: [
      TtsVoice(id: 'BV001_streaming', name: '梓欣·清新女声', gender: 'female', tags: ['自然', '温柔']),
      TtsVoice(id: 'BV002_streaming', name: '梓炀·沉稳男声', gender: 'male', tags: ['自然', '稳重']),
      TtsVoice(id: 'BV003_streaming', name: '梓萌·温柔知性', gender: 'female', tags: ['知性', '温柔']),
      TtsVoice(id: 'BV004_streaming', name: '梓涵·活泼元气', gender: 'female', tags: ['元气', '活泼']),
      TtsVoice(id: 'BV005_streaming', name: '梓轩·大气男声', gender: 'male', tags: ['沉稳', '大气']),
      TtsVoice(id: 'BV006_streaming', name: '梓瑶·甜美女声', gender: 'female', tags: ['甜美', '撒娇']),
      TtsVoice(id: 'BV007_streaming', name: '梓豪·阳光男声', gender: 'male', tags: ['阳光', '开朗']),
      TtsVoice(id: 'zh_female_qingxin', name: '清新女声', gender: 'female', tags: ['自然', '活泼']),
      TtsVoice(id: 'zh_female_shuangkuai', name: '爽快女声', gender: 'female', tags: ['干脆', '利落']),
      TtsVoice(id: 'zh_female_tianmei', name: '甜美女声', gender: 'female', tags: ['甜美', '可爱']),
      TtsVoice(id: 'zh_female_wenrou', name: '温柔女声', gender: 'female', tags: ['柔和', '细腻']),
      TtsVoice(id: 'zh_female_zhixing', name: '知性女声', gender: 'female', tags: ['成熟', '稳重']),
      TtsVoice(id: 'zh_female_gufeng', name: '古风女声', gender: 'female', tags: ['古典', '韵味']),
      TtsVoice(id: 'zh_male_chunhou', name: '醇厚男声', gender: 'male', tags: ['深沉', '稳重']),
      TtsVoice(id: 'zh_male_qingse', name: '青涩男声', gender: 'male', tags: ['年轻', '清爽']),
      TtsVoice(id: 'zh_male_jingying', name: '精英男声', gender: 'male', tags: ['商务', '干练']),
      TtsVoice(id: 'zh_female_vv_uranus', name: '情感女声·乌拉诺斯', gender: 'female', tags: ['情感', '多变']),
      TtsVoice(id: 'zh_male_vv_mars', name: '情感男声·马尔斯', gender: 'male', tags: ['情感', '多变']),
      TtsVoice(id: 'zh_female_sichuan', name: '四川话女声', gender: 'female', tags: ['方言', '四川']),
      TtsVoice(id: 'zh_male_sichuan', name: '四川话男声', gender: 'male', tags: ['方言', '四川']),
      TtsVoice(id: 'zh_female_cantonese', name: '粤语女声', gender: 'female', tags: ['方言', '粤语']),
    ],
  ),
  const TtsEngine(
    id: 'edge', name: 'Edge TTS', supportsCloning: false, authFields: [],
    voices: [
      TtsVoice(id: 'zh-CN-XiaoxiaoNeural', name: '小小·温柔', gender: 'female', tags: ['温柔']),
      TtsVoice(id: 'zh-CN-YunxiNeural', name: '云希·磁性', gender: 'male', tags: ['磁性']),
      TtsVoice(id: 'zh-CN-XiaoyiNeural', name: '小艺·活泼', gender: 'female', tags: ['活泼']),
      TtsVoice(id: 'zh-CN-YunhaoNeural', name: '云浩·稳重', gender: 'male', tags: ['稳重']),
      TtsVoice(id: 'zh-CN-YunxiaNeural', name: '云霞·成熟', gender: 'female', tags: ['成熟']),
      TtsVoice(id: 'zh-CN-YunjianNeural', name: '云健·运动', gender: 'male', tags: ['运动', '阳光']),
    ],
  ),
  const TtsEngine(id: 'system', name: '系统 TTS', supportsCloning: false, voices: []),
  const TtsEngine(
    id: 'gpt-sovits', name: 'GPT-SoVITS', supportsCloning: true,
    authFields: [AuthField(key: 'gpt_sovits_url', label: 'API 地址')],
    voices: [],
  ),
  const TtsEngine(
    id: 'custom', name: '自定义 TTS', supportsCloning: false,
    authFields: [AuthField(key: 'custom_tts_url', label: 'API 地址'), AuthField(key: 'custom_tts_key', label: 'API Key', secret: true)],
    voices: [],
  ),
];

TtsEngine? findTtsEngine(String id) {
  try { return allTtsEngines.firstWhere((e) => e.id == id); } catch (_) { return null; }
}
