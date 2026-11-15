# Solvhen v1.1 更新日志

## 未发布 — 屏幕操控内核（device 工具集）

### 新增

- **结构化 UI 树**：`device_screen` / `device_find` 把当前界面读成带稳定 id 的节点树（文字、控件类型、可点击/可输入/可滚动、坐标、层级）。模型不再只能看到一串扁平文本。
- **按 id 精准点击**：`device_tap` 用节点 id 点击，自动向上找可点击祖先，点不动才回退坐标手势——同名文字不会再点错。
- **等待而不是盲打**：`device_wait` 支持等文字出现或等界面稳定，`device_scroll` 支持滚动查找目标。
- **原子序列**：`device_act` 一次确认执行整段动作（点击→输入→等待→返回），避免逐步往返造成的界面漂移；最多 40 步，失败立即回报步号。
- **应用感知**：`device_app` 返回前台包名、应用名和窗口标题。
- **弹窗清理**：`device_dismiss` 默认只点「取消/关闭/跳过」，不主动点「允许」。
- **整屏截图**：`device_shot` 在 UI 树读不到内容时（游戏、视频、自绘界面）兜底，落地为 JPEG 文件。

### 安全

- 新增 `device` 能力开关（安全中心 → 屏幕操控），可整体关闭屏幕操控。
- 只读工具（screen/find/wait/app/shot）自动执行；点击、输入、滑动、关弹窗按 `modify` 处理，未开信任模式时逐次确认。
- `device_act` 始终逐次确认——它一次做多步，必须由人看着。

### 变更

- `accessibility_service_config.xml` 声明 `canTakeScreenshot`，截图需 Android 11+。
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
