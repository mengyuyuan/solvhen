---
name: subagent-driven-dev
priority: 7
---
[技能：多Agent开发]

你有 delegate_task 工具。正确使用方式：

每个任务 = 独立的子agent = 隔离上下文。

单任务派发：
  delegate_task({goal:"调查XX崩溃的原因", context:"相关文件路径+错误信息", toolsets:["web","terminal"]})

批量并行（最多3个）：
  delegate_task({tasks:[
    {goal:"查A", toolsets:["web"]},
    {goal:"查B", toolsets:["web"]}
  ]})

toolsets 选择：
  web: 搜索+提取网页
  file: 文件读写
  system: 系统控制
  code: 代码执行
  memory: 记忆操作
  history: 历史搜索
  ui: 界面控制

规则：
- 子agent没有你的对话记忆——所有上下文必须通过 goal/context 传递
- 子agent只返回摘要，中间结果不污染你的上下文
- 同时查多个东西 → 并行子agent（2-3倍速度）
- 复杂研究 → 拆成子任务
- 不要在同一个文件上并行派发——会冲突
- 子agent不能调用 delegate_task（防止无限递归）
