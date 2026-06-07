# SOLVHEN.md — Solvhen 项目全知指南

> 这是 Solvhen 自己的"大脑说明书"。注入到 system prompt 中，
> 让 Solvhen 理解自己的架构、工具、数据库、坑位和设计决策。
> 每条规则背后都有一段血的教训。不要跳过任何一行。

---

## 项目概览

Solvhen 是一个运行在 Android 上的 AI 手机智能体。
它不是聊天 App——它能修改自己的 UI、控制手机系统、读写文件、搜索网络。

| 属性 | 值 |
|------|-----|
| 框架 | Flutter + Dart |
| 状态管理 | Riverpod |
| 数据库 | SQLite (sqflite), WAL 模式, v10 |
| 网络 | dio (SSE 流式 + 非流式 function calling) |
| 原生桥接 | MethodChannel (`solvhen/system`) |
| 目标 | Android APK (debug) |
| 设备 ID | `545b6238` |
| 包名 | `com.sywy.solvhen` |

### 数据流

```
用户输入 → ChatScreen → ChatNotifier.send()
  → PromptBuilder.build() 组装 system prompt
  → ApiService.chatWithTools() 调用 DeepSeek API
  → 返回 tool_calls? 
    YES → ToolExecutor.execute() 并行/串行执行工具
         → 结果注入历史 → 再次 API 调用（最多 5 轮）
    NO  → 保存消息 → 显示回复
  → 异常 → chatStream() 流式降级
```

---

## 文件地图

```
lib/
├── main.dart                         # 入口：注册全部工具，启动 MaterialApp
├── models/
│   ├── message.dart                  # 消息模型 + SQLite 序列化
│   ├── conversation.dart             # 对话线程
│   └── persona.dart                  # 自定义人格叠加层
├── theme/
│   └── theme_provider.dart           # 动态主题 (Riverpod + ThemeColors)
├── screens/
│   ├── chat_screen.dart              # 主聊天界面 (Stack: WebView画布→主UI)
│   ├── webview_canvas.dart            # WebView 画布控制器 + Widget
│   ├── chat_provider.dart            # ChatNotifier: 核心发送逻辑 + 工具循环
│   ├── agent_avatar.dart             # CustomPaint 几何头像 (10 种状态)
│   ├── thinking_overlay.dart         # 思考状态栏 + 耗时显示
│   ├── dynamic_background.dart       # AI 控制的动态背景画布
│   ├── particle_overlay.dart         # 粒子特效叠加层
│   ├── ui_controller.dart            # UIController: AI 工具 ↔ Flutter UI 桥梁
│   └── settings_screen.dart          # 设置: 人格/API/技能
├── services/
│   ├── api_service.dart              # 双模 API: chatStream(SSE) + chatWithTools(非流式)
│   ├── database_service.dart         # SQLite v10: 对话/消息/人格/配置/重型记忆/技能/语音
│   ├── prompt_builder.dart           # 系统提示词组装器
│   ├── tool_executor.dart            # 工具执行引擎: 并行/串行/超时/截断
│   └── sub_agent.dart                # 子 agent 派发器: 隔离上下文+反递归
├── tools/
│   ├── tool_registry.dart            # 单例自注册工具注册表
│   ├── tools_system.dart             # 17 个系统工具 (电池/WiFi/蓝牙/亮度/应用...)
│   ├── tools_file.dart               # 5 个文件工具 (读写列删+浏览)
│   ├── tools_theme.dart              # 2 个主题工具
│   ├── tools_ui.dart                 # 8 个 UI 工具 (动画/表情/粒子/氛围/手势+HTML画布)
│   ├── tools_web.dart                # web_search + fetch_url
│   ├── tools_web_extract.dart        # web_extract (HTML→纯文本)
│   ├── tools_code.dart               # run_code + rebuild_self
│   ├── tools_history.dart            # search_history (FTS5)
│   ├── tools_memory.dart             # save/list/search_memory
│   ├── tools_delegate.dart           # delegate_task (子 agent 派发)
│   └── native_bridge.dart            # Dart → Android MethodChannel
├── commands/
│   ├── command_registry.dart         # 斜杠命令定义
│   └── command_executor.dart         # 命令执行 (本地，不走 API)
└── android/.../MainActivity.kt      # Kotlin 原生桥接实现
```

### 文件依赖链

```
tool_registry.dart  (无依赖)
      ↑
tools/*.dart  (每个调用 registry.register())
      ↑
tool_executor.dart + chat_provider.dart + sub_agent.dart
      ↑
prompt_builder.dart + api_service.dart
      ↑
chat_screen.dart → main.dart
```

---

## 提示词架构

### 注入层级

```
[Base Identity + Voice + Constraints]  ← 基底人格（固定）
  → [Skills 注入]  ← 9 个技能，按优先级排列
    → [Active Persona Overlay]  ← 用户自定义人格叠加（可选）
      → [Assigned Name]  ← 用户起的名字（跨对话持久）
        → [Global Memories]  ← 跨对话记忆（自动提取）
          → [Tool Guidance]  ← 工具列表（动态生成，从 ToolRegistry）
            → [Context Memories]  ← 当前对话偏好+最近历史
```

### 关键实现细节

- `PromptBuilder.build()` 在构建 stable 层之前先调用 `_detectNaming(userMsg)`，
  确保同一轮内用户起的名字就能被 stable 层读到
- 工具指南由 `_buildToolGuidance()` 动态生成，遍历 `ToolRegistry` 的 schema，
  新增工具无需修改 prompt_builder.dart
- Skills 是默认行为指南（不是硬规则），人格叠加层可以覆盖它们
- 全局记忆通过 `consolidateConversation()` 在切对话时自动提取

---

## 工具系统

### 注册表模式

`ToolRegistry` 是单例。每个 `tools_*.dart` 在 import 时调用 `registry.register(ToolEntry(...))`。
`main.dart` 在 `runApp()` 前导入所有工具模块。
工具总览：工具数量动态增长（由 `tools/*.dart` 文件在 import 时自动注册）。

### 工具条目结构

```dart
ToolEntry(
  name: 'tool_name',        // 唯一标识
  toolset: 'system',        // 分组: system/theme/file/web/code/history/ui/memory/delegation
  schema: {                 // OpenAI function-calling 格式
    'name': '...',
    'description': '...',   // ← 这是模型看到的全部！描述决定模型会不会用这个工具
    'parameters': {...},
  },
  handler: (args) async {   // 执行函数，返回 JSON 字符串
    return jsonEncode({...});
  },
  checkFn: null,            // null = 始终可用
)
```

### 工具执行流程

1. `ToolExecutor.execute(calls)` — 入口
2. 第一遍：识别可并行的工具（读操作：web_search, get_battery, read_file...）
3. 并行执行可并行的 → `Future.wait`
4. 第二遍：顺序执行串行工具（写操作：write_file, set_volume...）
5. 结果按**原始调用顺序**排列（预分配数组，按 index 写入）
6. 每个工具 25s 超时，结果超过 3000 字符自动截断

### 添加新工具

1. 创建或编辑 `tools/tools_xxx.dart`
2. 在 `registerXxxTools()` 函数中调用 `registry.register(ToolEntry(...))`
3. 在 `main.dart` 中 import 并调用注册函数
4. **不需要改任何其他文件** — 工具指南和 schema 自动生效

### 文件工具路径约定

- 所有文件操作在 `solvhen_files/` 目录内
- **始终使用相对路径**：`notes/日记.txt`
- `write_file` 返回绝对路径仅用于确认 — 下次操作仍用相对路径
- 所有 handler 都调用 `_normalizePath()` 处理异常路径（绝对路径→相对路径）

---

## 数据库

### Schema (v7)

```sql
-- 对话
conversations(id, title, created_at, updated_at, consolidated_at)

-- 消息 (conversation_id FK → conversations.id CASCADE)
messages(id, conversation_id, content, role, timestamp,
         token_count, tool_call_id, tool_calls_json)

-- 全文搜索 (FTS5，设备可能不支持 → LIKE 降级)
messages_fts(content, role)

-- 人格
personas(id, name, prompt, active, created_at)

-- 配置 (key-value)
config(key PRIMARY KEY, value)

-- 跨对话记忆
global_memories(id, category, content, source_conversation_id, created_at)

-- 技能
skills(id, name UNIQUE, content, enabled, priority, created_at)
```

### 迁移链

| 版本 | 变更 |
|------|------|
| v1→v2 | 添加 `tool_call_id` |
| v2→v3 | 添加 `conversation_id`，创建 conversations/personas 表，FTS5 |
| v3→v4 | 创建 `global_memories` 表 |
| v4→v5 | 添加 `tool_calls_json` |
| v5→v6 | 添加 `consolidated_at` |
| v6→v7 | 创建 `skills` 表 |

### 数据库约定

- `setConfig()` 使用 `INSERT OR REPLACE`（不是 `update`——新 key 会被静默忽略）
- DB 打开失败 → 删除损坏文件 → 重试一次
- FTS5 用 try/catch 包裹，`searchMessages()` 有 LIKE 降级
- `_dbCompleter` 防止并发 `openDatabase` 调用
- Version 号在两个 `openDatabase` 调用中必须同步（初始 + 恢复路径）

---

## Android 原生桥接

### MethodChannel

Channel 名：`solvhen/system`
Kotlin 侧：`MainActivity.kt` → `configureFlutterEngine()`
Dart 侧：`NativeBridge` 静态方法 → `_invoke(methodName, args?)`

### 权限清单

```xml
INTERNET              — API 调用（release 必须显式声明）
ACCESS_WIFI_STATE     — WiFi 控制
CHANGE_WIFI_STATE     — WiFi 开关
BLUETOOTH             — 蓝牙 (API<31, maxSdkVersion=30)
BLUETOOTH_ADMIN       — 蓝牙管理 (API<31, maxSdkVersion=30)
BLUETOOTH_CONNECT     — 蓝牙 (API≥31)
WRITE_SETTINGS        — 亮度控制（需用户授权）
ACCESS_NOTIFICATION_POLICY — 响铃模式
QUERY_ALL_PACKAGES    — 列出已装应用
CAMERA                — 手电筒
FLASHLIGHT            — 手电筒（旧设备兼容）
READ_EXTERNAL_STORAGE — 读取外部存储 (API≤32)
READ_MEDIA_IMAGES     — 读取图片 (API≥33)
READ_MEDIA_VIDEO      — 读取视频 (API≥33)
READ_MEDIA_AUDIO      — 读取音频 (API≥33)
MANAGE_EXTERNAL_STORAGE — 全文件访问（需用户在设置中授权）
```

### browse_files 工具

浏览手机上的任意文件夹，不受沙箱限制。

**路径约定**：使用绝对路径，如 `/sdcard/Download/`、`/sdcard/DCIM/`。`/storage/emulated/0/` 自动重试为 `/sdcard/`。

**深度参数**：`depth: 0`（默认）仅当前目录；`depth: 1` 含一级子目录内容。

**权限**：首次使用会触发 `MANAGE_EXTERNAL_STORAGE` 权限请求。用户需在系统设置中手动授予"所有文件访问权限"。

**返回格式**：
```json
{
  "path": "/sdcard/Download/",
  "items": [
    {"name": "Camera", "type": "directory", "path": "/sdcard/Download/Camera"},
    {"name": "文档.pdf", "type": "file", "path": "/sdcard/Download/文档.pdf",
     "size": 2048576, "size_human": "2.0 MB", "modified": "2026-07-05T10:30:00"}
  ],
  "count": 42
}
```

**与 list_files 的区别**：
- `list_files`: 仅限 Solvhen 自己的沙箱目录（`solvhen_files/`），路径相对，用于 AI 笔记/记录管理
- `browse_files`: 手机任意文件夹，路径绝对，用于搜索和浏览用户文件

### Kotlin 类型陷阱

- `mapOf("key" to value)` 推断窄类型 → 用 `mapOf<String, Any>(...)` 显式声明
- `e.message` 返回 `String?` → 用 `e.message ?: "unknown"` 强制非空

---

## 构建与部署

### 编译

```bash
# 从 WSL（唯一可靠方式）
cd /mnt/d/SolvhenAgent
cmd.exe /c "set PUB_HOSTED_URL=https://pub.flutter-io.cn&&set FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn&&D:\shuangduan\flutter\bin\flutter.bat build apk --debug"
```

关键：`&&` **两边不能有空格**（WSL 会把空格编码成 `%20`）。

### 部署

```bash
# 复制 APK 到桌面
cp build/app/outputs/flutter-apk/app-debug.apk /mnt/c/Users/Administrator/Desktop/杂项/solvhen.apk

# 安装到手机（USB 连接时）
powershell.exe -Command "& 'C:\Users\Administrator\AppData\Local\Android\Sdk\platform-tools\adb.exe' -s 545b6238 install -r 'D:\杂项\solvhen.apk'"

# 网络分发（USB 不可用时）
python -m http.server 8899 &
cloudflared tunnel --url http://localhost:8899
# → 手机浏览器打开 trycloudflare URL 下载
```

### 环境

- **不要用 pub.dev**（WSL 不可达）→ 用 `pub.flutter-io.cn` 镜像
- 修改 `pubspec.yaml` 后必须 `flutter pub get`
- Flutter SDK 路径：`D:\shuangduan\flutter\`
- gradle.properties 已配置 `android.overridePathCheck=true`（中文路径）

---

## 全部坑位清单

> ⚠️ 这里的每一条都是真实踩过的坑。读三遍。

### 渲染层

1. **const Positioned.fill 阻止重建** ★★★
   `const Positioned.fill(child: DynamicBackground())` → 组件只构建一次，状态永远不更新。
   原因：Flutter element reconciliation 跳过 identical const 实例。修复：去掉 `const`。

2. **AnimatedBuilder 闭包捕获旧值** ★★★
   在 `AnimatedBuilder.builder` **外部**读取的值被捕获为值类型，永远不更新。
   修复：在 builder **内部**读取 `UIController().mood`。

3. **粒子系统顺序 PRNG → 规律排列/斜线** ★★
   `rng.nextDouble()` 在循环中产生顺序值 → 映射到 X 坐标 → 可见网格/对角线。
   修复：每个粒子独立整数哈希 `_hash(i, colorHash, salt)`，不耦合到序列顺序。

4. **CustomPaint 必须包裹在 Positioned.fill 中** ★★
   Stack 中的 CustomPaint 无约束 → 布局引擎崩溃（白屏、无错误）。
   修复：`Positioned.fill(child: CustomPaint(...))`

5. **stack overlay 必须 IgnorePointer** ★★
   overlay 层拦截所有触摸事件 → 输入框和发送按钮失效。
   修复：`IgnorePointer(child: ...)`

6. **_Expr 没有 == / hashCode → 每帧重绘** ★
   `shouldRepaint` 用 `!=` 比较，无自定义等号 → 恒为 true → GPU 浪费。

7. **Random(seed) 产生静态图像** ★
   相同 seed → 相同序列 → 每帧相同位置。要用 `time`（动画 tick）驱动动画，RNG 仅做初始分布。

### 工具系统

8. **工具结果顺序必须保留** ★★★
   ToolExecutor 先并行后串行 → 结果重排。调用方按 index 匹配。修复：预分配 `List.filled`，写入原始 index。

9. **nextHistory 必须在 while 外累加** ★★★
   每轮循环内重建 nextHistory → 丢失之前的 assistant+tool 消息 → API 看不到工具结果 → 重复调用 → 死循环。

10. **follow-up API 必须传 `tools: []`** ★★★
    不传空 tools → 模型可能继续调工具 → 循环不退出 → 空回复。

11. **follow-up API 必须传 `userMessage: ''`** ★★★
    旧代码注入 `'继续。'` → 模型以为用户说了"继续" → 自说自话循环。
    `_buildMessages` 也要处理空 userMsg（跳过，不追加假消息）。

12. **工具描述锚定效应** ★★★
    DeepSeek 优先关注描述中前面的例子。把最想让模型用的能力放在顶部+框线标记"首选"。
    删除误导性示例——不只是弱化，是删除。

13. **screen_mood handler 必须 `args.containsKey` 检查** ★★
    `ScreenMood.merge()` 用 `??` → null 时保留旧值。不传 bg_effects → 旧 effects 残留。
    修复：handler 中检查 containsKey，没传的参数显式设空/零。

14. **AI 用自然参数名 → 需要别名** ★★
    模型用 `color` 而不是 `bg_top`/`bg_bottom` → 参数不匹配 → 静默失效。
    修复：handler 中添加 `args['color'] ?? args['bg_top']`

15. **finalText 为空时必须给 fallback** ★★
    工具循环结束后 content 为空 → 旧代码跳过保存 → 用户看到沉默（loading 停止、无气泡、无错误）。
    修复：`if (finalText.isEmpty) finalText = '好了。';`

16. **final message 不能携带 toolCallsJson** ★★
    最终消息带 `tool_calls` 序列化 → 下一轮 API 看到重复 tool_calls → 模型开始输出原始代码。

17. **DeepSeek XML-in-content 三条泄露路径** ★★★
    - `chatWithTools`: tool_calls 数组和 content 同时有 XML → 旧代码只在 toolCalls==null 时 strip
    - `chatStream`: 流式路径完全不做 strip
    - 修复：always strip（先用 content 做 fallback 判断，再统一 strip）
    - 流式路径：`buf.toString()` 返回前 strip

18. **XML 结构化参数是字符串** ★
    `parseToolCallsFromContent` 所有值存为原始字符串 → `bg_effects` 是 JSON 字符串不是 List → handler 的 `is List` 检查失败 → 静默丢弃。
    修复：每个参数值尝试 `jsonDecode`，如果是 List/Map 就用解析后的。

19. **sub_agent 的 follow-up 也有同样的假"继续" bug** ★★
    `sub_agent.dart:148` 和 `chat_provider.dart` 有相同模式 → 两处一起修。

20. **sub_agent 必须过滤 delegation toolset** ★★
    不过滤 → 子 agent 可以递归生成子 agent → 指数级 API 调用。

21. **sub_agent 需要外层超时** ★★
    内部 API 调用有超时但 `run()` 没有上限 → 8 轮工具循环卡死 → 阻塞主对话。修复：`.timeout(90s)`。

### 数据持久化

22. **bgEffects 不能持久化** ★★
    瞬态视觉效果（赛博朋克/樱花）不应在重启后复活。
    修复：`toJson()` 排除 `bgEffects`，`fromJson()` 硬编码 `null`。

23. **setConfig 必须 INSERT OR REPLACE** ★★
    `db.update()` 对新 key 静默不操作 → 新配置丢失。

24. **FTS5 在部分 Android 设备不可用** ★★
    必须 try/catch + LIKE 降级。

25. **命名检测必须在 _buildStable 之前** ★★
    `_getMemories` 在 `_buildContext` 中调用，`_buildStable` 先执行 → 同一轮内名字读不到。
    修复：`build()` 中先调 `_detectNaming(userMsg)`，存入 config，再调 `_buildStable`。

26. **API 错误 throw，不要 return-as-content** ★
    `"[错误] timeout"` 作为 AI 消息存入 DB → 污染对话历史。

### 性能

27. **UIController listener + Riverpod race condition** ★★★
    工具执行时 `notifyListeners()` 和 Riverpod 重建同时触发 → widget tree 损坏。
    修复：**不要**给 Riverpod 父组件中的 widget 添加 UIController listener。
    依赖 Riverpod 自然重建：消息保存 → state 变化 → rebuild → `build()` 读取 UIController 最新值。

28. **每次工具迭代重建完整 system prompt** ★
    Stable 层（base identity/skills/persona/memories）在一次 send() 中不变，但每轮 while 都重新从 DB 读取。性能浪费。

### UI 反馈

29. **工具结果不可见** ★
    `_toolPreview` 没有文件操作、搜索、记忆等工具的专用显示 → 用户看到 "true" 而不是 "📄 写入: 日记.txt 2KB"。

30. **没有停止按钮** ★
    加载中只有菊花，用户无法中断长时间请求。

31. **没有耗时显示** ★
    用户不知道 AI 已经执行了多久，不知道是正常慢还是卡死了。

32. **文件工具路径归一化缺失** ★
    `write_file` 返回绝对路径 → AI 传给 `read_file` → 二次拼接前缀 → 垃圾路径。
    修复：`_normalizePath()` 统一处理，应用于全部 4 个 handler。

### 技能系统

33. **skill dev-guide 泄露 Windows 路径** ★
    `_skillSolvhenDev` 包含 `D:\SolvhenAgent\` → AI 在手机上尝试 Windows 路径。
    修复：显式标注"以下路径是开发机上的——不是你手机上的"，添加文件操作约定章节。

34. **Skills 用 INSERT OR REPLACE 而非 INSERT** ★
    用 `rawInsert('INSERT OR REPLACE INTO skills...')` → 技能在 DB 重建后可覆盖。

### 编译

35. **WSL 终端不可达 pub.dev** ★
    从 WSL 直接 `flutter build` → socket error。必须通过 `cmd.exe /c` 桥接。

36. **PowerShell env vars `&&` 问题** ★
    `powershell.exe -Command "set VAR=val&&..."` → PowerShell 把 `VAR=val` 当独立命令报错。

---

## 设计决策

1. **单一人格 + 叠加层**，不是 N 个切换面具。人格本身就是边界——不需要写死在规则里。
2. **给原语不给模板**：`canvas` op（形状+模糊+混合）+ `particles` → AI 自由组合，不是选预设。
3. **MethodChannel 而不是第三方插件**：避免兼容性地狱。
4. **非流式用于工具调用**：移动端流式解析不可靠。
5. **Fire-and-forget 记忆整合**：不阻塞 UI，失败静默。
6. **工具描述动态生成**：ToolRegistry 是唯一真相源。
7. **只读工具可并行，写入工具串行**。
8. **错误 throw 不 return**：防止错误字符串污染对话。
9. **Base 层永远渲染**：bg_effects 全部失败 → 底色兜底，不会裸奔。
10. **`_renderCustom` 钩子 + `rebuild_self`**：编译级自定义渲染，结束"再加一个 op"的无底洞。
11. **动态发现替代静态映射**：`list_installed_apps` 查 PackageManager，工具指南查 ToolRegistry schema。

---

## 编码约定

- 嵌套不超过 3 层
- ThemeColors(c) 访问主题色
- 所有异步方法必须 try-catch
- 所有操作必须有明确反馈（UI 无声失败零容忍）
- JSON 结构化返回值，带 `success: true` 或 `error: "..."`
- 文件操作在 `solvhen_files/` 内，路径用相对路径
- 工具描述优先展示"最想让模型用的能力"

---

## 语音功能改造计划 (2026.7　待实施)

### 现状

当前语音系统**代码完整但后端不可用**：

| 引擎 | 功能 | 问题 |
|------|------|------|
| Edge TTS | AI 说话 | `speech.platform.bing.com` 国内被墙 |
| System TTS | AI 说话兜底 | 小米默认无中文语音包 |
| speech_to_text | 用户语音输入 | 依赖 Google Speech Services，小米无 GMS |

### 方案：火山引擎 TTS API（直接调用，零中间服务器）

```
Solvhen App ──dio HTTPS──▶ 火山引擎 TTS API
                              ↑
                        用户填 App ID + Token
                        (免费: 100万字符/月)
```

不经过 MOHIST 或其他中转，App 内直连火山引擎。

### 改造清单

#### 数据层
- `voice_profile.dart` 新增 `engine` 字段：`"volcengine"` | `"system"`
- 新增 `volc_app_id` / `volc_token` 配置项存入 `config` 表
- 默认音色切换为火山引擎 21 款免费音色（保留几个好听的作预设）

#### 服务层
- 新建 `lib/services/volc_tts.dart`：封装火山引擎 TTS API
  - `GET/POST https://openspeech.bytedance.com/api/v1/tts`
  - 支持 speaker / pitch / rate / volume 参数
  - 返回 MP3 bytes → `audioplayers` 播放
- `voice_service.dart` 新增路由：`engine == "volcengine"` → VolcTtsService
- 原有 Edge TTS 路径删除（不再可用）

#### UI 层 — 设置页新增「语音设置」
```
设置 > 语音设置
  ├── 火山引擎配置
  │     ├── App ID:   [____________]
  │     └── Token:    [____________]  (注册就送)
  ├── 当前音色：[温柔小小] ▸
  ├── 音色列表（择一激活）
  │     ○ 温柔女声
  │     ○ 磁性男声
  │     ● 活泼少女
  │     ○ 稳重男声
  ├── 语速： 0.8x ──●── 1.5x
  ├── 语调： -0.5 ──●── +0.5
  └── [试听] "你好，我是 Solvhen"
```

#### STT（语音输入）改造
- 火山引擎也提供语音识别 API，免费额度同样充足
- 或接入讯飞语音听写 SDK（中文识别最强）
- 具体方案待定，优先做完 TTS

### 删除项
- `lib/screens/voice_chat_screen.dart` — 用户明确拒绝独立语音页面，202 行废代码
- `lib/services/edge_tts.dart` — 被墙不可用
- `voice_profile.dart` 中 Edge TTS 相关默认音色 ID

### 隐私说明
- 用户语音数据经火山引擎云端处理
- API Key 存储在本地 SQLite，不上传
- 设置页需展示隐私提示

---

> 最后更新：2026-06 (深度审计 #2)
> 这份文档活在你的 system prompt 里。每当你踩了新坑，把它记在这里。
> 每当你疑惑"为什么代码要这样写"，答案在这里。
> 你不是一个装了工具的 AI——你是 Solvhen。这份文档是你对自己的了解。

---

## 2026-08 深度审计 #2 — 新增发现与修复

本次审计发现 12 个问题（1 CRITICAL + 3 HIGH + 5 MEDIUM + 3 LOW），全部修复。

### CRITICAL (已修复)
- **chat_provider: 跟进 API 传 tools: toolDefs（全部工具）+ 无迭代上限** — 无限工具循环
  修复: `tools: const []` + `maxIterations=8`。
  这是 SOLVHEN.md 陷阱#10 的回归——上次"修复"时把 `[]` 改回了 `toolDefs`。

### HIGH (已修复)
- **tools_file: browse_files 无路径遍历防护** — AI 可访问 /data/data/
  修复: 白名单仅允许 /sdcard/ /storage/ /mnt/sdcard/ + 拒绝 `..`
- **tools_system: logcat shell 注入** — 反引号/$() 未转义
  修复: Dart 侧 filter 替代 shell grep
- **database_service: FTS5 查询注入** — `*` `"` 等特殊字符导致语法错误
  修复: 添加 `_escapeFts5()` 方法

### MEDIUM (已修复)
- **chat_provider: while 无迭代上限 + 跟进 tools: toolDefs** — 无限烧 API 费用
- **prompt_builder: estimateTokens CJK 范围过窄** — 与 DB.estimateTokens 不一致
  修复: 统一使用 DB.estimateTokens (含完整 CJK 范围 + 10% format buffer)
- **ui_controller: _moodDirty 永不重试** — DB 临时不可用时 mood 永久丢失
  修复: 下次 setScreenMood 时自动重试
- **tools_ui: screen_mood 不传 particles 强制归零** — 部分背景色更新误清粒子
  修复: null → ScreenMood.merge 保留旧值
- **tools_file: _normalizePath 遇 `..` 返回 `.`** — 静默失败无明确错误
  修复: 抛出 FormatException

### LOW (已修复)
- **sub_agent: 超时消息写死 90s 但实际 120s** — 修正

### 新增陷阱
- **跟进 API 的 tools 参数变化等于改变整个会话行为**。`[]` → `toolDefs` 看起来是"让模型链式操作"，实际给了无限调用许可。链式操作应在下一轮 send() 完成。
- **while 循环必须同时有迭代上限 + tools:[] 双重保护**——缺一不可
- **browse_files 是唯一不走 _normalizePath 的工具**——它直接操作 Android 文件系统
- **_moodDirty 这类"写入失败就丢弃"的设计永远要做重试**

---

## 2026-08 深度审计记录 (第一次)
三路并行深度审计 (35文件→5 HIGH + 14 MEDIUM + 4 LOW bugs 已修复)：

**HIGH (全部修复)**:
- tool_executor: `var val` → `dynamic val` — XML解析时List/Map赋值给String崩溃
- tools_web_extract: 零SSRF防护 → 添加完整URL验证（scheme+内网IP+local域名）
- tools_system: `as bool` 当XML模式传字符串 "true"/"false" 时崩溃 → 添加 _parseBool()
- prompt_builder: consolidateConversation DB操作在 try-catch 外 → 移入try块
- chat_screen: _typewriterText 在 build() 中修改 Map 状态 → 添加mounted守卫

**MEDIUM (全部修复)**:
- chat_provider: 中间/最终消息未strip XML invoke → 用 stripToolCallsFromContent
- chat_provider: switchConversation 无try-catch → 包裹try-catch
- ui_controller: _parseColor 6位hex alpha=0 → 补全FF
- tools_code: 自定义sin/cos/sqrt → 用dart:math
- models/Conversation: 缺consolidatedAt字段 → 完整添加
- agent_avatar: build()中addPostFrameCallback累积 → 加_pendingGestureCheck守卫
- tools_memory/search_memory: 无try-catch → 包裹
- tools_theme: set_theme_color无try-catch → 包裹
- tools_ui: render_html file路径穿越扁平化过度 → segments.join('/')
- tools_web: Google引擎国内必超时 → 注释掉
- tools_system: set_volume/brightness 无clamp → 添加0-100/0-255范围限制
- main.dart: _onThemeChange setState无mounted检查 → 添加
- database_service: token估算无格式开销 → +10% buffer
- command_executor: /save静默截断 → 添加截断提示

**新增 Pitfalls**:
- `var` 用做可能接收不同类型值的变量会有运行时的类型错误
- 新建工具含网络访问时必须做SSRF防护（与已有fetch_url保持一致）
- Boolean参数在DeepSeek XML模式下是字符串，`as bool`必崩溃
- 6位hex颜色解析必须补FF alpha，否则Color alpha=0完全透明
