# Solvhen v1.1 更新日志

## 新增

- **动态头像系统**：替换旧版几何 CustomPaint，16 帧手绘 PNG 头像。10 个眼球方向（正/上下左右/四角）+ 6 帧眨眼序列。8 状态动画引擎（idle/thinking/speaking/searching/coding/reading/writing/confused），3 档眨眼速度自适应，呼吸缩放 + 弹跳动效
- **App 图标**：午夜蓝宝石底色 + 冰白几何线条，替代旧版默认图标

## 修复

- 工具调用循环无迭代上限 → 加 maxIterations=8 + 跟进 API 强制纯文本
- browse_files 无路径白名单 → 仅允许 /sdcard/ /storage/ /mnt/sdcard/
- logcat Shell 注入 → Dart 侧 filter 替代 shell grep
- FTS5 查询语法未转义 → 添加 _escapeFts5()
- screen_mood 部分更新误清粒子密度 → null 保留旧值
- UI mood 持久化失败永不重试 → 下次写入自动重试
- 路径遍历静默失败 → 抛出明确错误
- token 估算 PromptBuilder 与 DB 两套实现不一致 → 统一为 DB 版本
- 子 Agent 超时提示 90s 实际 120s → 修正

## 优化

- 按钮性能：UniqueKey 移除
- 死代码清理：未用变量/import/方法
- 三处重复 _parseColor 标注待合并
