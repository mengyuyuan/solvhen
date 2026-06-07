# Skills Schema

> Solvhen 技能系统的约定和索引。按 Karpathy wiki 模式组织。
> 每个技能是一个 .md 文件，带 YAML frontmatter。SkillLoader 在启动时扫描并同步到 SQLite。

## Domain

Solvhen AI 手机智能体的行为指南。技能定义 Solvhen 的能力边界、行为规范和领域知识。

## Conventions

- 文件名：`kebab-case.md`，与 frontmatter 中的 `name` 字段一致
- 每个 .md 文件以 YAML frontmatter 开头：`name`（必填）、`priority`（必填）、`description`（可选）
- Priority 决定注入顺序：100 = 最高（project-context），3 = 最低（ui-expression）
- 正文第一行以 `[技能：...]` 开头作为标题
- 修改技能后重新编译 APK，SkillLoader 会用 INSERT OR REPLACE 更新 DB
- 新增技能：添加 .md 文件 → 在 `skill_loader.dart` 的 `_manifest` 中注册 → 重新编译

## Frontmatter

```yaml
---
name: skill-name          # 唯一标识，与文件名一致
priority: 10              # 注入优先级 (0-100)
description: 一句话描述    # 可选，供人类阅读
---
```

## Index

| 文件 | 优先级 | 摘要 |
|------|--------|------|
| [[project-context.md]] | 100 | Solvhen 的架构、数据流、文件地图、全部 21 个坑位和设计决策 |
| [[web-search-guide.md]] | 10 | 搜索习惯——何时搜索、如何验证信息、结果优先级 |
| [[memory-protocol.md]] | 10 | 记忆保存触发条件、回复前检查、分类约定 |
| [[solvhen-dev-guide.md]] | 8 | 项目架构、编译命令、DB schema、文件操作约定 |
| [[systematic-debugging.md]] | 8 | 4 阶段根因调试法、反模式警示 |
| [[subagent-driven-dev.md]] | 7 | delegate_task 使用方式、toolsets 选择、并行规则 |
| [[dart-flutter-patterns.md]] | 6 | Flutter/Dart 常用模式、性能约定 |
| [[conversation-style.md]] | 5 | 对话节奏控制、毒舌分寸、沉默使用 |
| [[tool-usage.md]] | 5 | 工具分类、调用原则、多 agent 委派 |
| [[ui-expression.md]] | 3 | 界面工具使用时机、性格驱动的表达强度 |

## Cross-References

- `project-context.md` ← 被所有技能引用（最基础的架构知识）
- `web-search-guide.md` ↔ `memory-protocol.md`（搜索和记忆是互补的认知习惯）
- `tool-usage.md` ↔ `ui-expression.md`（工具分类和使用时机互补）
- `solvhen-dev-guide.md` → `dart-flutter-patterns.md`（开发指南引用编码模式）
- `systematic-debugging.md` → `project-context.md`（调试时参考坑位清单）

## Update Policy

- 踩了新坑 → 更新 `project-context.md` 的坑位清单 + bump priority 不变
- 新增技能 → 添加 .md 文件 + 在此 index 中注册 + `skill_loader.dart` manifest
- 废弃技能 → 从 manifest 移除 + 标记为 `_archived: true` + 保留文件作为历史
- 优先级调整 → 改 frontmatter 的 `priority` + 更新此 index 的顺序

---

> 最后更新：2026-07-05 | 总技能数：10
