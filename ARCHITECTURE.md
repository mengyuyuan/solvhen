# Solvhen 架构重整计划

> 目标：将技能、人格从硬编码字符串改为独立文件，
> 建立 Hermes 风格的文件→DB 同步管道，消除 database_service.dart 的巨型字符串常量。

## 当前问题

```
database_service.dart  (900行)
  ├── DB schema + 迁移        ← 合理
  ├── CRUD 操作               ← 合理
  └── 10 个技能内容常量        ← 不该在这（共 ~250 行字符串）
      _skillWebSearch, _skillMemory, _skillConversation,
      _skillToolUsage, _skillUIExpression, _skillSolvhenDev,
      _skillDebug, _skillSubAgentDev, _skillDartFlutter,
      _skillProjectContext

prompt_builder.dart  (460行)
  ├── 组装逻辑                ← 合理
  └── 3 个基底人格常量         ← 不该在这（共 ~90 行字符串）
      _baseIdentity, _baseVoice, _baseConstraints
```

技能更新需要改 Dart 源码 + 重新编译。人格修改同理。
新增技能 = 往 database_service.dart 塞更多字符串。

## 目标架构

```
SolvhenAgent/
├── assets/
│   ├── skills/                    # 技能文件（构建时打包进 APK）
│   │   ├── web-search-guide.md
│   │   ├── memory-protocol.md
│   │   ├── conversation-style.md
│   │   ├── tool-usage.md
│   │   ├── ui-expression.md
│   │   ├── solvhen-dev-guide.md
│   │   ├── systematic-debugging.md
│   │   ├── subagent-driven-dev.md
│   │   ├── dart-flutter-patterns.md
│   │   └── project-context.md
│   └── personality/               # 人格文件（构建时打包进 APK）
│       ├── base-identity.md
│       ├── base-voice.md
│       └── base-constraints.md
├── lib/
│   ├── services/
│   │   ├── database_service.dart  # 瘦身：删掉全部 _skill* 常量
│   │   ├── skill_loader.dart      # 新增：扫描 assets/skills/ → upsert DB
│   │   └── personality_loader.dart # 新增：从 assets/personality/ 读人格
│   ├── screens/
│   │   └── prompt_builder.dart    # 瘦身：删掉 _base* 常量，改用 PersonalityLoader
│   └── (其余不变)
```

### 数据流向

```
┌─────────────────────────────────────────────────────────┐
│  构建时                                                  │
│  assets/skills/*.md  ────打包──→  APK 内 assets/        │
│  assets/personality/*.md ──打包──→  APK 内 assets/      │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  运行时（首次启动 / 每次启动）                            │
│                                                         │
│  SkillLoader.scan()                                      │
│    ├─ 列举 assets/skills/ 下所有 .md 文件                │
│    ├─ 解析 YAML frontmatter: name, priority, description │
│    ├─ 读取正文作为 skill content                         │
│    └─ upsert 到 SQLite skills 表 (INSERT OR REPLACE)     │
│                                                         │
│  PersonalityLoader.load()                                │
│    ├─ rootBundle.loadString('assets/personality/*.md')  │
│    └─ 返回组装好的 system prompt 片段                    │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  提示词构建时                                            │
│                                                         │
│  PromptBuilder.build()                                   │
│    ├─ PersonalityLoader.loadIdentity()  → _baseIdentity  │
│    ├─ PersonalityLoader.loadVoice()     → _baseVoice     │
│    ├─ PersonalityLoader.loadConstraints() → _baseConstraints │
│    ├─ DB.getEnabledSkills()  → 技能内容（来自文件→DB同步）│
│    ├─ DB.getActivePersona()  → 用户人格（DB原生）         │
│    └─ (其余层不变)                                       │
└─────────────────────────────────────────────────────────┘
```

## 技能文件格式

每个 `assets/skills/*.md` 带 YAML frontmatter：

```markdown
---
name: web-search-guide
priority: 10
description: 搜索习惯——何时搜索、如何验证信息
---

[技能：搜索习惯]
你拥有 web_search 和 web_extract 工具。养成以下习惯：

1. 实时信息必须搜索...
```

`SkillLoader` 解析 frontmatter → `name` 作为 SQLite key，`priority` 控制注入顺序，正文是 `content`。

## 人格文件格式

纯文本，无 frontmatter。直接作为 system prompt 片段注入：

```
# assets/personality/base-identity.md
你是 Solvhen。

[人格：理性为骨，怜悯为血，求知为眼，耐心为根基，锋芒为舌。
这些都是你——不是可以切换的面具，是你同时拥有的全部。]
...
```

## 实施步骤

### Phase 1：提取技能文件（不改运行逻辑）

1. 创建 `assets/skills/` 目录
2. 把 `database_service.dart` 中 10 个 `_skill*` 常量的内容逐一写入对应的 `.md` 文件
3. 加 YAML frontmatter（name + priority）
4. 创建 `lib/services/skill_loader.dart`
5. 创建 `lib/services/personality_loader.dart`
6. 更新 `pubspec.yaml` 添加 assets 声明
7. **此时不删旧代码**——新旧两套并行，验证通过后再切

### Phase 2：接入运行时

8. `SkillLoader.scan()` 在 `main.dart` 或 `ChatNotifier._init()` 中调用
9. 扫描 `assets/skills/` → 解析 → `DB.addSkill()` upsert
10. `PersonalityLoader` 替换 `prompt_builder.dart` 中的硬编码常量
11. 验证：DB 中 skills 表数据正确，prompt 组装正确

### Phase 3：清理

12. 删除 `database_service.dart` 中全部 `_skill*` 常量（约 250 行）
13. 删除 `prompt_builder.dart` 中 `_baseIdentity/_baseVoice/_baseConstraints` 常量
14. 删除 `_create()` 中的技能 seeding 代码（SkillLoader 替代）
15. 完整编译 + 测试

### Phase 4：增强（可选）

16. 支持热更新：从 `solvhen_files/skills/` 读取用户自定义技能文件
17. 用户可在设置界面编辑/新增技能（保存为文件→下次启动生效）
18. 人格文件也支持用户覆盖

## 关键设计决策

| 决策 | 理由 |
|------|------|
| 技能文件打包进 assets | APK 内只读，避免运行时文件权限问题 |
| DB 仍存储技能 | enabled/disabled 状态需要持久化；content 从文件同步到 DB 作为缓存 |
| 人格文件也打包进 assets | 基底人格是产品定义的一部分，不应散落在字符串常量里 |
| 用户人格保留在 DB | 用户创建的人格是动态数据，不适合静态文件 |
| SkillLoader 用 upsert | INSERT OR REPLACE → 文件更新后自动覆盖 DB 旧内容 |

## 影响范围

| 文件 | 变更类型 |
|------|----------|
| `assets/skills/*.md` (10个) | 新建 |
| `assets/personality/*.md` (3个) | 新建 |
| `lib/services/skill_loader.dart` | 新建 |
| `lib/services/personality_loader.dart` | 新建 |
| `lib/services/database_service.dart` | 删 ~250 行 |
| `lib/services/prompt_builder.dart` | 删 ~90 行 + 改为调用 PersonalityLoader |
| `lib/screens/chat_provider.dart` | 调用 SkillLoader.scan() |
| `pubspec.yaml` | 加 assets 声明 |
| `lib/main.dart` | 可选：启动时调用 SkillLoader |

## 不改变的部分

- **工具系统**：34 个工具注册方式不变（已经是文件化的，每个 `tools_*.dart` 注册）
- **DB schema**：v7 足够，skills 表结构不变
- **UI 层**：chat_screen、settings_screen 无需改动
- **API 层**：api_service、tool_executor、sub_agent 无需改动
- **原生桥接**：NativeBridge、MainActivity.kt 无需改动

---

> 这份计划描述了 Solvhen 从"硬编码字符串仓库"到"文件驱动架构"的迁移路径。
> 实施时按 Phase 顺序推进，每个 Phase 结束后编译验证。
> 原则：新旧并行，验证后切——不冒进。
