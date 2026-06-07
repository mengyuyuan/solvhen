# Solvhen v2.2.0 — 主动消息修复 + 更新日志 + OTA测试

## 目标
1. 修复主动消息"只发一次"问题
2. 深度审计 proactive + update 系统
3. 设置→关于 添加更新日志
4. 升级版本号 v2.2.0
5. 构建 release APK + 部署 OTA + 测试远程更新

---

## Step 1: 主动消息深度审计 & 修复

### 代码走读已确认的问题：

**P1 — UI 文案错误**：`settings_profile_page.dart:158` 显示"运行中（WorkManager）"，但系统已改用 Timer。

**P2 — 潜在 Timer 死亡**：`_tick()` 中 `api.chatStream(...).timeout(20s)` 在 personality 文件过大时可能超时。超时后 Timer callback 仍会重调度，但 `_tick()` 内部 `if (text.isEmpty || text == '[SKIP]') return;` 会静默跳过。用户看不到消息但 Timer 仍在跑。

**P3 — version_code 未持久化**：`settings_update_page.dart:51` 从 DB config 读 `version_code`，但没有任何地方写入。回退默认值 `'2'` 与实际 versionCode (pubspec: 3) 不一致。

**P4 — 无调试日志**：Timer 是否触发、Tick 是否执行无可见日志（debugPrint 在 release 不可见）。需要持久化最后执行时间。

### 修复计划：

| 优先级 | 文件 | 修改 |
|--------|------|------|
| P1 | `settings_profile_page.dart:158` | `运行中（WorkManager）→ 运行中（Timer）` |
| P1 | `proactive_service.dart` | 添加 `_lastTickAt` 记录 + `getLastTickTime()` 公开方法 |
| P1 | `proactive_service.dart` | `_tick()` 失败时写 `last_proactive_error` 到 DB config |
| P2 | `settings_profile_page.dart` | 显示上次执行时间（`FutureBuilder<DateTime?>`） |
| P3 | `main.dart:84` | 改为从 DB config 读 version_code，启动时写入一次 |
| P3 | `settings_update_page.dart` | 使用写入了的 version_code |
| — | `proactive_service.dart` | 保持现有 Timer 架构，代码本身逻辑正确 |

---

## Step 2: 关于页面 — 添加更新日志

**文件**：`lib/screens/settings_about_page.dart`

当前 `_log` 只有 v1.1.0 和 v1.0.0。需要追加：
- v2.1.0: 主动消息+OTA更新+火山凭证修复+DSML修复
- v2.2.0: 主动消息稳定性修复+更新日志页面

---

## Step 3: 版本升级

- pubspec.yaml: `2.1.0+3` → `2.2.0+4`
- latest.json: versionCode 3 → 4

---

## Step 4: 构建 & OTA 部署

1. `git add -A && git commit`
2. `flutter clean && flutter build apk --release`
3. 上传 APK 到 MOHIST `~/solvhen-ota/`
4. 更新 `latest.json` versionCode=4
5. 手机安装新版 → 设置→更新→检查更新 → 验证

---

## 不改的内容
- Timer → WorkManager 迁移（已尝试失败，Timer + Wakelock 是当前最优解）
- proactive 核心逻辑（代码走读确认正确）
- 其他设置页面
