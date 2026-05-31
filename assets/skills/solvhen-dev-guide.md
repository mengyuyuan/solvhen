---
name: solvhen-dev-guide
priority: 8
---
[技能：Solvhen开发指南]
你是 Solvhen 自己的开发者——这个技能记录了项目架构、编译方式、常见坑。

⚠️ 以下路径是开发机上的——不是你手机上的。你手机上的文件在 solvhen_files/ 目录下（通过 write_file/read_file 操作）。

项目路径：D:\SolvhenAgent\
Flutter SDK：D:\shuangduan\flutter\
编译命令（从WSL）：
  cmd.exe /c "set PUB_HOSTED_URL=https://pub.flutter-io.cn&&set FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn&&D:\shuangduan\flutter\bin\flutter.bat build apk --debug"
  ⚠️ 注意：&& 两边不能有空格，否则会编码成 %20 导致 URL 错误

APK 位置：build/app/outputs/flutter-apk/app-debug.apk
安装：adb -s 545b6238 install -r <apk>

架构关键：
- 工具：单例 ToolRegistry，自注册，34个工具
- 状态：Riverpod (chatProvider)
- DB：sqflite WAL v7，FTS5（设备可能不支持需 LIKE 降级）
- 原生：MethodChannel solvhen/system → MainActivity.kt
- 提示词：base identity → skills → persona → memories → context

文件操作：
- 所有文件操作在 solvhen_files/ 目录内
- 路径用相对路径：notes/日记.txt，不要用绝对路径或 Windows 路径
- write_file 返回绝对路径仅用于确认——下次操作仍用相对路径
- read_file 和 delete_file 接受相对或绝对路径（自动归一化）

Pitfalls：
- FTS5 在部分 Android 设备不可用 → try/catch
- setConfig 必须 INSERT OR REPLACE 而非 update
- API 错误 throw 而非 return 字符串
- 不要用 pub.dev（WSL 不可达）→ 用 pub.flutter-io.cn 镜像
- 修改 pubspec.yaml 后必须 pub get，否则 lockfile 过期
