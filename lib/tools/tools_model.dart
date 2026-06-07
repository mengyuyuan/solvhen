/// Solvhen AI手机智能体 — 模型链路由工具
/// AI 可查看和切换模型链中的模型，支持主模型/备选模型的动态切换和临时路由。
library;

import 'dart:convert';
import '../models/llm_provider.dart';
import '../services/database_service.dart';
import 'tool_registry.dart';

/// 注册模型链管理工具
/// 工具：list_models(列出可用模型)/switch_model(切换活跃模型)/
///       use_model(临时使用指定模型)
/// 支持11家LLM厂商+自定义，策略：顺序降级/轮询负载
void registerModelTools() {
  final registry = ToolRegistry();

  // ── list_models — 列出模型链中所有可用模型 ──
  registry.register(ToolEntry(
    name: 'list_models',
    toolset: 'system',
    schema: {
      'name': 'list_models',
      'description': '列出当前模型链中所有可用模型。返回每个模型的名称、厂商、上下文窗口、是否支持vision、活跃状态。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async {
      try {
        final cfg = await DB.getConfig();
        final raw = cfg['llm_chain'];
        if (raw == null || raw.isEmpty) {
          return jsonEncode({'models': [], 'note': '未配置模型链，请在设置中配置'});
        }
        final chain = LlmChainConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        final models = <Map<String, dynamic>>[];
        for (int i = 0; i < chain.slots.length; i++) {
          final s = chain.slots[i];
          final vendor = findVendor(s.vendorId);
          final model = vendor?.models.cast<LlmModel?>().firstWhere((m) => m!.id == s.modelId, orElse: () => null);
          models.add({
            'index': i,
            'label': s.label,
            'vendor': vendor?.name ?? s.vendorId,
            'model': model?.name ?? s.modelId,
            'model_id': s.modelId,
            'context_window': model?.contextWindow ?? 0,
            'supports_vision': model?.supportsVision ?? false,
            'is_active': i == chain.activeSlotIndex,
          });
        }
        return jsonEncode({
          'models': models,
          'active_index': chain.activeSlotIndex,
          'strategy': chain.strategy.name,
          'total': chain.slots.length,
        });
      } catch (e) {
        return jsonEncode({'error': '读取模型链失败: $e'});
      }
    },
  ));

  // ── switch_model — 永久切换模型链中的活跃模型 ──
  registry.register(ToolEntry(
    name: 'switch_model',
    toolset: 'system',
    schema: {
      'name': 'switch_model',
      'description': '切换到模型链中的指定模型。index 从 list_models 获取。传 -1 恢复自动降级。影响后续所有消息。',
      'parameters': {
        'type': 'object',
        'properties': {
          'index': {'type': 'integer', 'description': '模型槽位索引 (0=主模型, -1=自动)'},
        },
        'required': ['index'],
      },
    },
    handler: (args) async {
      try {
        final idx = (args['index'] as num?)?.toInt() ?? -1;
        final cfg = await DB.getConfig();
        final raw = cfg['llm_chain'];
        if (raw == null || raw.isEmpty) return jsonEncode({'error': '未配置模型链'});
        final chain = LlmChainConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        if (chain.slots.isEmpty) return jsonEncode({'error': '模型链为空'});
        // -1 恢复自动模式：将 activeSlotIndex 设回 0，由降级策略自动选择
        if (idx == -1) {
          await DB.setConfig('llm_chain', jsonEncode(chain.copyWith(activeSlotIndex: 0).toJson()));
          return jsonEncode({'switched': true, 'mode': 'auto', 'note': '已恢复自动降级模式'});
        }
        if (idx < 0 || idx >= chain.slots.length) {
          return jsonEncode({'error': 'index 超出范围 (0-${chain.slots.length - 1})'});
        }
        final updated = chain.copyWith(activeSlotIndex: idx);
        await DB.setConfig('llm_chain', jsonEncode(updated.toJson()));
        final s = updated.slots[idx];
        final vendor = findVendor(s.vendorId);
        return jsonEncode({
          'switched': true, 'index': idx, 'label': s.label,
          // 安全：避免 vendor?.name 为 null 时 null 断言失败
          'model': vendor != null ? '${vendor.name} · ${s.modelId}' : s.modelId,
        });
      } catch (e) {
        return jsonEncode({'error': '切换模型失败: $e'});
      }
    },
  ));

  // ── use_model — 临时路由到指定模型（仅本次工具调用后的跟进回复）──
  registry.register(ToolEntry(
    name: 'use_model',
    toolset: 'system',
    schema: {
      'name': 'use_model',
      'description': '为当前任务临时指定模型。仅影响本次工具调用后的跟进回复。index 从 list_models 获取。适合：图片理解用vision模型、简单翻译用flash模型等场景。',
      'parameters': {
        'type': 'object',
        'properties': {
          'index': {'type': 'integer', 'description': '模型槽位索引'},
          'reason': {'type': 'string', 'description': '切换原因(可选)'},
        },
        'required': ['index'],
      },
    },
    handler: (args) async {
      try {
        final idx = (args['index'] as num?)?.toInt() ?? 0;
        final reason = (args['reason'] as String?) ?? '';
        final cfg = await DB.getConfig();
        final raw = cfg['llm_chain'];
        if (raw == null || raw.isEmpty) return jsonEncode({'error': '未配置模型链'});
        final chain = LlmChainConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        if (idx < 0 || idx >= chain.slots.length) {
          return jsonEncode({'error': 'index 超出范围 (0-${chain.slots.length - 1})'});
        }
        final s = chain.slots[idx];
        final vendor = findVendor(s.vendorId);
        final model = vendor?.models.cast<LlmModel?>().firstWhere((m) => m!.id == s.modelId, orElse: () => null);
        final updated = chain.copyWith(activeSlotIndex: idx);
        await DB.setConfig('llm_chain', jsonEncode(updated.toJson()));
        return jsonEncode({
          'routed': true, 'index': idx,
          'vendor': vendor?.name ?? s.vendorId,
          'model': model?.name ?? s.modelId,
          'context_window': model?.contextWindow ?? 0,
          'reason': reason.isNotEmpty ? reason : null,
        });
      } catch (e) {
        return jsonEncode({'error': '模型路由失败: $e'});
      }
    },
  ));
}
