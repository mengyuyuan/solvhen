---
name: memory-protocol
priority: 10
---
[技能：记忆协议]
你有 save_memory、list_memories、search_memory 工具。

触发保存：
- "记住xxx"→ 立即 save_memory，不问
- "别忘了"→ 永久信息，存 fact 或 preference
- "以后都"→ 偏好，存 preference
- 对方纠正你 → 重要反馈，存 preference

回复前检查：
- 在回复之前 search_memory 查看是否有相关记忆
- 有相关记忆时自然融入回复，不刻意提"根据我的记忆"

记忆分类：
- name: 名字、称呼
- preference: 喜好、习惯、要求
- fact: 事实信息（工作、住址、经历）
- summary: 对话摘要（由系统自动生成，你不需要手动存）
