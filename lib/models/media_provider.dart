// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 媒体生成提供商——图片(147ai/OpenAI/ComfyUI)+视频(可灵/Runway/ComfyUI)槽位管理
// ═══════════════════════════════════════════════════════════════

library;



// ── Common ──

class MediaModel {
  final String id;
  final String name;
  final String? resolution;
  const MediaModel({required this.id, required this.name, this.resolution});
}

class MediaSlot {
  final String slotId;
  final String vendorId;
  final String modelId;
  final String? customUrl;
  final String? apiKey;
  const MediaSlot({required this.slotId, required this.vendorId, required this.modelId, this.customUrl, this.apiKey});

  Map<String, dynamic> toJson() => {
    'slotId': slotId, 'vendorId': vendorId, 'modelId': modelId,
    if (customUrl != null) 'customUrl': customUrl,
    if (apiKey != null) 'apiKey': apiKey,
  };
  factory MediaSlot.fromJson(Map<String, dynamic> j) => MediaSlot(
    slotId: j['slotId'] as String, vendorId: j['vendorId'] as String,
    modelId: j['modelId'] as String, customUrl: j['customUrl'] as String?,
    apiKey: j['apiKey'] as String?,
  );
  MediaSlot copyWith({String? vendorId, String? modelId, String? customUrl, String? apiKey}) => MediaSlot(
    slotId: slotId, vendorId: vendorId ?? this.vendorId, modelId: modelId ?? this.modelId,
    customUrl: customUrl ?? this.customUrl, apiKey: apiKey ?? this.apiKey,
  );
}

// ── Image vendors ──

class ImageVendor {
  final String id;
  final String name;
  final String? defaultUrl;
  final List<MediaModel> models;
  const ImageVendor({required this.id, required this.name, this.defaultUrl, this.models = const []});
}

final allImageVendors = [
  const ImageVendor(id: '147ai', name: '147ai', defaultUrl: 'https://api.147ai.com',
    models: [MediaModel(id: 'gpt-image-2-client', name: 'GPT Image 2', resolution: '2560×1440')]),
  const ImageVendor(id: 'openai', name: 'OpenAI', defaultUrl: 'https://api.openai.com/v1',
    models: [MediaModel(id: 'dall-e-3', name: 'DALL-E 3', resolution: '1024×1024'), MediaModel(id: 'dall-e-2', name: 'DALL-E 2', resolution: '1024×1024')]),
  const ImageVendor(id: 'comfyui', name: 'ComfyUI', defaultUrl: 'http://localhost:8188', models: []),
  const ImageVendor(id: 'custom', name: '自定义', models: []),
];

ImageVendor? findImageVendor(String id) {
  try { return allImageVendors.firstWhere((v) => v.id == id); } catch (_) { return null; }
}

// ── Video vendors ──

class VideoVendor {
  final String id;
  final String name;
  final String? defaultUrl;
  final List<MediaModel> models;
  const VideoVendor({required this.id, required this.name, this.defaultUrl, this.models = const []});
}

final allVideoVendors = [
  const VideoVendor(id: 'kling', name: '可灵 Kling', defaultUrl: 'https://api.klingai.com',
    models: [MediaModel(id: 'kling-v1-6', name: 'Kling 1.6', resolution: '1920×1080')]),
  const VideoVendor(id: 'runway', name: 'Runway', defaultUrl: 'https://api.runwayml.com',
    models: [MediaModel(id: 'gen3-alpha', name: 'Gen-3 Alpha', resolution: '1280×768')]),
  const VideoVendor(id: 'comfyui', name: 'ComfyUI', defaultUrl: 'http://localhost:8188', models: []),
  const VideoVendor(id: 'custom', name: '自定义', models: []),
];

VideoVendor? findVideoVendor(String id) {
  try { return allVideoVendors.firstWhere((v) => v.id == id); } catch (_) { return null; }
}

// ── Slots storage ──

List<MediaSlot> imageSlotsFromJson(List? list) => list?.map((e) => MediaSlot.fromJson(e as Map<String, dynamic>)).toList() ?? [];
List<MediaSlot> videoSlotsFromJson(List? list) => list?.map((e) => MediaSlot.fromJson(e as Map<String, dynamic>)).toList() ?? [];
List<Map<String,dynamic>> slotsToJson(List<MediaSlot> slots) => slots.map((s) => s.toJson()).toList();
