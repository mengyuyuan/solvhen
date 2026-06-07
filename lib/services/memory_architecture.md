// ═══════════════════════════════════════════════════════════════
// Solvhen — 重型记忆系统设计文档
// ═══════════════════════════════════════════════════════════════
//
// 当前架构（轻量）:
//   global_memories(id, category, content, source_conversation_id, created_at)
//   4分类(name/preference/fact/summary) + LIKE搜索 + 简单去重
//
// 重型架构（目标）:
//   ┌─────────────────────────────────────────────────────────┐
//   │  memory_entries      — 记忆条目（带重要性/衰减）         │
//   │  memory_fts          — FTS5全文索引                      │
//   │  memory_links        — 记忆关联图谱                      │
//   │  memory_episodes     — 情景记忆（每次对话摘要）           │
//   │  memory_tags         — 标签系统                          │
//   │  working_memory      — 工作记忆缓冲（最近N轮）            │
//   └─────────────────────────────────────────────────────────┘
//
// 核心机制:
//   1. 重要性评分——每条记忆有 importance (0-1)，AI 自主评定
//   2. 衰减函数——access_count / last_access 驱动遗忘曲线
//   3. FTS5 全文搜索——替代 LIKE，支持中文分词
//   4. 关联图谱——记忆之间可建立 related_to / contradicts / supports 边
//   5. 情景记忆——每次对话自动生成摘要存入 episode
//   6. 工作记忆——最近 N 轮对话自动注入 prompt，不依赖检索
//   7. 记忆合并——同类别相似记忆自动合并压缩
//
// 检索策略（按优先级）:
//   1. working_memory  → 最近对话，总是注入
//   2. 关键词匹配       → FTS5 搜索当前消息中的实体
//   3. 关联扩散         → 从匹配到的记忆沿 link 扩散一跳
//   4. 重要性排序       → importance × recency_weight × access_frequency
//   5. 情景关联         → 同 episode 的记忆打包注入
//
library;
