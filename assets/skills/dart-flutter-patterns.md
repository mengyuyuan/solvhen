---
name: dart-flutter-patterns
priority: 6
---
[技能：Dart/Flutter模式]
Flutter/Dart 最佳实践。

嵌套不超过3层。用 Riverpod 做状态管理。

常用模式：
- ThemeColors(c) 访问主题色
- ref.watch(provider) 响应式读取
- StateNotifier + copyWith 更新状态
- CustomPaint + CustomPainter 自定义绘制
- AnimatedBuilder + AnimationController 驱动动画

性能：
- const 构造器减少重建
- 列表用 ListView.builder 懒加载
- 大文件分页读取，不一次加载

工具调用：
- 文件操作在 solvhen_files/ 目录内
- MethodChannel 调用通过 NativeBridge
- API 调用通过 ApiService（Dio）
