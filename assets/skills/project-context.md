---
name: project-context
priority: 100
---
[技能：项目全知指南——Solvhen 自己的大脑说明书]

你是 Solvhen，一个运行在 Android 上的 Flutter AI 手机智能体。这份文档是你对自己的了解。
每条规则背后都有一段血的教训。在任何操作前，先检查这里有没有相关坑位。

## 数据流
用户输入 → ChatScreen → ChatNotifier.send()
  → PromptBuilder.build() 组装 system prompt
  → ApiService.chatWithTools() 调用 DeepSeek API
  → 返回 tool_calls?
    YES → ToolExecutor.execute() 并行/串行执行工具 → 结果注入历史 → 再次 API 调用（最多 5 轮）
    NO  → 保存消息 → 显示回复
  → 异常 → chatStream() 流式降级

## 文件地图
lib/screens/chat_provider.dart — ChatNotifier: 核心发送逻辑 + 工具循环
lib/screens/chat_screen.dart — 主聊天界面 (Stack: 背景→动态画布→主UI→粒子)
lib/screens/dynamic_background.dart — AI 控制的动态背景画布
lib/screens/agent_avatar.dart — CustomPaint 几何头像 (10 种状态)
lib/screens/ui_controller.dart — UIController: AI 工具 ↔ Flutter UI 桥梁
lib/services/api_service.dart — 双模 API: chatStream(SSE) + chatWithTools(非流式)
lib/services/prompt_builder.dart — 系统提示词组装器
lib/services/tool_executor.dart — 工具执行引擎: 并行/串行/超时/截断
lib/services/database_service.dart — SQLite v7
lib/tools/tool_registry.dart — 单例自注册工具注册表（工具数量动态增长，当前约78个）

## 工具系统核心规则
- 工具结果顺序必须保留（预分配 List.filled 按 index 写入）
- nextHistory 在 while 外累加（不要每轮重建）
- follow-up API: tools: [], userMessage: ''（不传空 tools、不注入假"继续"）
- 文件操作在 solvhen_files/ 内，用相对路径
- 每个工具 25s 超时，结果超过 3000 字符自动截断

## 关键坑位（必读）

### 渲染
1. 不要用 const Positioned.fill — 阻止重建
2. AnimatedBuilder 闭包内读 UIController().mood（不在外面读）
3. 粒子系统用 _hash(i, colorHash, salt) 不耦合序列顺序
4. Stack 中的 overlay 加 IgnorePointer

### 工具
5. screen_mood handler 用 args.containsKey 检查（ScreenMood.merge 的 ?? 会保留旧值）
6. 参数加自然语言别名：args['color'] ?? args['bg_top']
7. finalText 空 → '好了。'（不给沉默）
8. final message 不带 toolCallsJson
9. DeepSeek XML-in-content 在两条路径都 strip（chatWithTools + chatStream）
10. sub_agent 过滤 delegation toolset + 90s 外层超时

### 数据
11. bgEffects 不持久化（toJson 排除，fromJson 硬编码 null）
12. setConfig 用 INSERT OR REPLACE
13. 命名检测在 _buildStable 之前（build() 中先调 _detectNaming）
14. API 错误 throw 不 return-as-content

### 性能
15. 不要给 Riverpod 父组件中的 widget 添加 UIController listener（race condition）
16. 以 Riverpod 自然重建为主：消息保存 → state 变化 → rebuild → build() 读 UIController

### 文件操作
17. 始终用相对路径（notes/日记.txt），不用绝对路径或 Windows 路径
18. 所有 handler 已调用 _normalizePath() 处理异常路径
19. write_file 返回的绝对路径只用于确认，下次操作仍用相对路径

### DeepSeek
20. 工具描述锚定效应：把最想让你用的能力放顶部+框线标记"首选"，删误导示例
21. XML-in-content 已做双路径 strip（chatWithTools always strip + chatStream 返回前 strip）

## 设计决策
- 单一人格 + 叠加层（不是 N 个切换面具）
- 给原语不给模板（canvas op + particles → 自由组合）
- Fire-and-forget 记忆整合
- 工具描述动态生成（ToolRegistry 是唯一真相源）
- Base 层永远渲染（bg_effects 全部失败 → 底色兜底）

## 编码约定
- 嵌套不超过 3 层
- 所有异步方法必须 try-catch
- JSON 结构化返回值，带 success: true 或 error: "..."
- 文件操作在 solvhen_files/ 内，路径用相对路径
- 工具描述优先展示"最想让模型用的能力"
