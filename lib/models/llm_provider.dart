// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// LLM提供商注册表——11家官方验证的LLM厂商+模型+模型链配置
// ═══════════════════════════════════════════════════════════════

library;



// ── Vendor & Model ──

class LlmVendor {
  final String id;
  final String name;
  final String defaultUrl;
  final List<LlmModel> models;
  const LlmVendor({required this.id, required this.name, required this.defaultUrl, required this.models});
}

class LlmModel {
  final String id;
  final String name;
  final int contextWindow;
  final bool supportsVision;
  const LlmModel({required this.id, required this.name, this.contextWindow = 131072, this.supportsVision = false});
}

// ── Verified vendor registry (all from official docs) ──

final allVendors = [
  // 1. DeepSeek — api-docs.deepseek.com
  const LlmVendor(id: 'deepseek', name: 'DeepSeek', defaultUrl: 'https://api.deepseek.com/v1', models: [
    LlmModel(id: 'deepseek-v4-pro', name: 'V4 Pro', contextWindow: 131072),
    LlmModel(id: 'deepseek-v4-flash', name: 'V4 Flash', contextWindow: 131072),
    LlmModel(id: 'deepseek-reasoner', name: 'R1 (推理)', contextWindow: 65536),
  ]),
  // 2. OpenAI — platform.openai.com/docs/models
  const LlmVendor(id: 'openai', name: 'OpenAI', defaultUrl: 'https://api.openai.com/v1', models: [
    LlmModel(id: 'gpt-4o', name: 'GPT-4o', contextWindow: 128000, supportsVision: true),
    LlmModel(id: 'gpt-4o-mini', name: 'GPT-4o Mini', contextWindow: 128000, supportsVision: true),
    LlmModel(id: 'o3-mini', name: 'o3-mini', contextWindow: 200000),
    LlmModel(id: 'o4-mini', name: 'o4-mini', contextWindow: 200000),
  ]),
  // 3. Anthropic — docs.anthropic.com
  const LlmVendor(id: 'claude', name: 'Claude', defaultUrl: 'https://api.anthropic.com/v1', models: [
    LlmModel(id: 'claude-sonnet-4-20250514', name: 'Sonnet 4', contextWindow: 200000, supportsVision: true),
    LlmModel(id: 'claude-opus-4-20250514', name: 'Opus 4', contextWindow: 200000, supportsVision: true),
  ]),
  // 4. Google Gemini — ai.google.dev
  const LlmVendor(id: 'gemini', name: 'Gemini', defaultUrl: 'https://generativelanguage.googleapis.com/v1beta', models: [
    LlmModel(id: 'gemini-2.5-pro', name: '2.5 Pro', contextWindow: 1048576, supportsVision: true),
    LlmModel(id: 'gemini-2.5-flash', name: '2.5 Flash', contextWindow: 1048576, supportsVision: true),
  ]),
  // 5. 豆包/火山引擎 — volcengine.com/docs/82379
  const LlmVendor(id: 'doubao', name: '豆包', defaultUrl: 'https://ark.cn-beijing.volces.com/api/v3', models: [
    LlmModel(id: 'doubao-seed-2-0-pro-260215', name: 'Seed 2.0 Pro', contextWindow: 256000),
    LlmModel(id: 'doubao-seed-2-0-flash-260215', name: 'Seed 2.0 Flash', contextWindow: 256000),
    LlmModel(id: 'doubao-seed-1-6-thinking-260215', name: 'Seed 1.6 Thinking', contextWindow: 256000),
    LlmModel(id: 'doubao-1-5-vision-pro-32k', name: 'Vision Pro 32K', contextWindow: 32768, supportsVision: true),
  ]),
  // 6. 通义千问/阿里百炼 — help.aliyun.com/zh/model-studio
  const LlmVendor(id: 'qwen', name: '通义千问', defaultUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1', models: [
    LlmModel(id: 'qwen3-max', name: 'Qwen3 Max', contextWindow: 131072),
    LlmModel(id: 'qwen-plus', name: 'Qwen Plus', contextWindow: 131072),
    LlmModel(id: 'qwen-turbo', name: 'Qwen Turbo', contextWindow: 1000000),
    LlmModel(id: 'qwen-vl-plus', name: 'Qwen VL Plus', contextWindow: 32768, supportsVision: true),
  ]),
  // 7. 智谱 GLM — open.bigmodel.cn
  const LlmVendor(id: 'glm', name: '智谱 GLM', defaultUrl: 'https://open.bigmodel.cn/api/paas/v4', models: [
    LlmModel(id: 'glm-5.1', name: 'GLM 5.1', contextWindow: 128000),
    LlmModel(id: 'glm-5v-turbo', name: 'GLM 5V Turbo', contextWindow: 32768, supportsVision: true),
  ]),
  // 8. 百度文心 — cloud.baidu.com
  const LlmVendor(id: 'ernie', name: '文心一言', defaultUrl: 'https://qianfan.baidubce.com/v2', models: [
    LlmModel(id: 'ernie-4.5-8k', name: 'ERNIE 4.5', contextWindow: 8192),
    LlmModel(id: 'ernie-speed-pro', name: 'ERNIE Speed Pro', contextWindow: 8192),
  ]),
  // 9. 讯飞星火 — xfyun.cn
  const LlmVendor(id: 'spark', name: '讯飞星火', defaultUrl: 'https://spark-api-open.xf-yun.com/v1', models: [
    LlmModel(id: 'spark-x2-flash', name: 'Spark X2 Flash', contextWindow: 32768),
    LlmModel(id: 'spark4.0-ultra', name: 'Spark 4.0 Ultra', contextWindow: 8192),
  ]),
  // 10. MiniMax — platform.minimaxi.com
  const LlmVendor(id: 'minimax', name: 'MiniMax', defaultUrl: 'https://api.minimax.chat/v1', models: [
    LlmModel(id: 'MiniMax-M2.7', name: 'M2.7', contextWindow: 131072),
    LlmModel(id: 'MiniMax-M2.5', name: 'M2.5', contextWindow: 131072),
  ]),
  // 11. 月之暗面 Kimi — platform.moonshot.cn
  const LlmVendor(id: 'kimi', name: 'Kimi', defaultUrl: 'https://api.moonshot.cn/v1', models: [
    LlmModel(id: 'kimi-k2', name: 'Kimi K2', contextWindow: 128000),
  ]),
  // 12. 自定义
  const LlmVendor(id: 'custom', name: '自定义', defaultUrl: '', models: []),
];

LlmVendor? findVendor(String id) {
  try { return allVendors.firstWhere((v) => v.id == id); } catch (_) { return null; }
}

// ── Slot ──

class LlmSlot {
  final String slotId;
  final String label;
  final String vendorId;
  final String modelId;
  final String? customUrl;
  final String? apiKey;
  const LlmSlot({required this.slotId, required this.label, required this.vendorId, required this.modelId, this.customUrl, this.apiKey});

  LlmSlot copyWith({String? slotId, String? label, String? vendorId, String? modelId, String? customUrl, String? apiKey}) => LlmSlot(
    slotId: slotId ?? this.slotId, label: label ?? this.label, vendorId: vendorId ?? this.vendorId,
    modelId: modelId ?? this.modelId, customUrl: customUrl ?? this.customUrl, apiKey: apiKey ?? this.apiKey,
  );
  Map<String, dynamic> toJson() => {
    'slotId': slotId, 'label': label, 'vendorId': vendorId, 'modelId': modelId,
    if (customUrl != null) 'customUrl': customUrl, if (apiKey != null) 'apiKey': apiKey,
  };
  factory LlmSlot.fromJson(Map<String, dynamic> j) => LlmSlot(
    slotId: j['slotId'] as String, label: j['label'] as String, vendorId: j['vendorId'] as String,
    modelId: j['modelId'] as String, customUrl: j['customUrl'] as String?, apiKey: j['apiKey'] as String?,
  );
}

// ── Chain strategy ──

enum ChainStrategy { sequential, roundRobin }

extension ChainStrategyExt on ChainStrategy {
  String get label => switch (this) { ChainStrategy.sequential => '顺序降级', ChainStrategy.roundRobin => '轮询负载' };
  String get desc => switch (this) {
    ChainStrategy.sequential => '主模型失败/超时 → 自动切下一个',
    ChainStrategy.roundRobin => '每次请求轮流使用下一个模型',
  };
}

// ── Full chain config ──

class LlmChainConfig {
  final ChainStrategy strategy;
  final List<LlmSlot> slots;
  final int activeSlotIndex;
  const LlmChainConfig({this.strategy = ChainStrategy.sequential, this.slots = const [], this.activeSlotIndex = 0});

  LlmSlot? get activeSlot => slots.isNotEmpty && activeSlotIndex < slots.length ? slots[activeSlotIndex] : null;

  Map<String, dynamic> toJson() => {
    'strategy': strategy.name, 'activeSlotIndex': activeSlotIndex,
    'slots': slots.map((s) => s.toJson()).toList(),
  };
  factory LlmChainConfig.fromJson(Map<String, dynamic> j) => LlmChainConfig(
    strategy: ChainStrategy.values.firstWhere((s) => s.name == j['strategy'], orElse: () => ChainStrategy.sequential),
    activeSlotIndex: (j['activeSlotIndex'] as int?) ?? 0,
    slots: (j['slots'] as List?)?.map((e) => LlmSlot.fromJson(e as Map<String, dynamic>)).toList() ?? [],
  );
  LlmChainConfig copyWith({ChainStrategy? strategy, List<LlmSlot>? slots, int? activeSlotIndex}) => LlmChainConfig(
    strategy: strategy ?? this.strategy, slots: slots ?? this.slots, activeSlotIndex: activeSlotIndex ?? this.activeSlotIndex,
  );
}
