# Plan: 彻底修复主动消息 + 发布 v2.1.0 正式版

## 根因分析（深度）

主动消息不工作的**唯一根因**：WorkManager 回调在 headless isolate 中调用 `rootBundle.loadString()` 抛异常。

```
proactiveCallbackDispatcher → runProactiveTick() → _loadPersonality()
→ rootBundle.loadString() → 💥 No Flutter engine in headless isolate
→ catch returns false → WorkManager marks task as failed → 静默死亡
```

不是 Timer 的问题。Timer + 前台通知在主 isolate 中有完整 Flutter 环境，人格/记忆/通知全部正常。

## 方案：移除 WorkManager，纯 Timer + 前台通知

### 为什么这样可以

Timer 在主 isolate 运行，调用链完整：
```
Timer.fire → _tick() → rootBundle ✅ → DB ✅ → API ✅ → Notification ✅ → re-schedule ✅
```

前台通知 `ongoing:true` 给 Android "这个进程很重要" 的信号，短间隔（分钟级）下不会被杀。

### 额外加固：Timer 回调防崩

当前 Timer 回调中 `DB.getConfig()` 无 try/catch。DB 锁住时抛异常 → 回调中断 → 不再重调度 → Timer 永久死亡。

**加固**：整个回调体用 try/catch 包裹，任何异常都确保重调度。

## 执行步骤

### Step 1: 移除 WorkManager
- `pubspec.yaml`: 删 `workmanager: ^0.9.0`
- `lib/main.dart`: 删 `Workmanager().initialize()` + import
- `lib/services/proactive_service.dart`: 删 `proactiveCallbackDispatcher`、`runProactiveTick()`、WorkManager 注册/取消、import

### Step 2: 纯 Timer + 加固
- `_tick()` 保持现有逻辑（人格+记忆+冲突检测+API+通知）
- Timer 回调体 try/catch 包裹，异常后仍重调度
- 保留 2 分钟冲突窗口

### Step 3: 版本 2.1.0
- `pubspec.yaml`: `version: 2.1.0+3`
- `latest.json`: `versionCode: 3`

### Step 4: 端到端验证
1. `dart analyze` → 0 warning
2. Debug 编译 → 设 1 分钟间隔 → 等 1 分钟 → 通知到
3. 回复消息 → 等 2 分钟 → 再次收到
4. Release 编译 → 上传 OTA

## 文件变更
| 文件 | 操作 |
|------|------|
| `pubspec.yaml` | 删 workmanager，version → 2.1.0+3 |
| `lib/main.dart` | 删 WorkManager init + import |
| `lib/services/proactive_service.dart` | 回退纯 Timer + try/catch 加固 |
| `latest.json` (MOHIST) | versionCode → 3 |

## 风险评估
- Timer 在设备深度睡眠后可能延迟 → **可接受**（前台通知保活，短间隔下极少发生）
- 小米极端省电模式可能杀进程 → **可接受**（Android 平台固有限制，WorkManager 同样无解）
- 人格/记忆加载 → **无风险**（主 isolate，完整 Flutter 环境）
