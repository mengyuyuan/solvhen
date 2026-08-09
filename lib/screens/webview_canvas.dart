// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// WebView画布——Android PlatformView渲染HTML画布，AI可动态绘制视觉效果
// ═══════════════════════════════════════════════════════════════

library;

///
/// Replaces the complex Flutter visual layer with a single WebView.
/// Solvhen controls it via the `render_html` tool.
/// HTML content is session-only. It is cleared on app/conversation changes so
/// an old Android PlatformView can never be replayed over a fresh chat.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/database_service.dart';

// ═══════════════════════════════════════════════
// Controller — singleton, tool talks to this
// ═══════════════════════════════════════════════

/// WebView画布控制器（单例）——管理多个WebView实例
/// ⚠️ Android PlatformView必须在Expanded/SizedBox中才能渲染
/// ⚠️ 不能放在Stack顶层（会崩溃）
class WebViewCanvasController {
  static final WebViewCanvasController _instance = WebViewCanvasController._();
  factory WebViewCanvasController() => _instance;
  WebViewCanvasController._();

  final _controllers = <WebViewController>[];
  final _updateQueue = <_HtmlUpdate>[];
  String? _lastHtml; // cached for persistence

  /// 画布是否有实际内容（非空白页）。Widget 根据此值决定是否渲染 WebView，
  /// 避免空白 PlatformView 持续占用 GPU 合成资源导致动画卡顿。
  final ValueNotifier<bool> hasContent = ValueNotifier(false);

  /// 每次内容变化都递增。不能只监听 [hasContent]：连续两次 renderHtml
  /// 都是 true，ValueNotifier 不会通知，WebView 就无法重新挂载和冻结。
  final ValueNotifier<int> revision = ValueNotifier(0);

  /// The default blank page — transparent canvas.
  static const blankPage = '<!DOCTYPE html><html><head>'
      '<meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">'
      '<style>'
      '*{margin:0;padding:0;box-sizing:border-box}'
      'html,body{width:100%;height:100%;background:transparent;overflow:hidden}'
      '#c{position:fixed;top:0;left:0;width:100%;height:100%}'
      '</style>'
      '</head><body><div id="c"></div></body></html>';

  /// Keep current HTML only for the active app session.
  Future<void> _saveHtml(String html) async {
    _lastHtml = html;
  }

  /// Never replay HTML on startup. Stale persisted values from older builds
  /// are removed as part of the one-way safety migration.
  Future<String> getStartupHtml() async {
    _lastHtml = null;
    try {
      await DB.setConfig('canvas_html', '');
    } catch (_) {}
    return blankPage;
  }

  void _onReady(WebViewController ctrl) {
    if (!_controllers.contains(ctrl)) _controllers.add(ctrl);
    _flushQueue();
  }

  void _onDispose(WebViewController ctrl) {
    _controllers.remove(ctrl);
    if (_controllers.isEmpty) {
      _updateQueue.clear();
    }
  }

  Future<void> _flushQueue() async {
    if (_updateQueue.isEmpty || _controllers.isEmpty) return;
    final batch = List<_HtmlUpdate>.from(_updateQueue);
    _updateQueue.clear();
    for (final ctrl in _controllers) {
      for (final u in batch) {
        try {
          await _apply(ctrl, u);
        } catch (e) {/* log error */}
      }
    }
  }

  Future<void> renderHtml(String html, {String mode = 'replace'}) async {
    if (mode == 'replace') await _saveHtml(html);

    // 通知所有 WebViewCanvas widget：画布有内容，需要渲染
    hasContent.value = true;
    revision.value++;

    final update = _HtmlUpdate(html: html, mode: mode);
    // Broadcast to all active WebViews
    final controllers = List<WebViewController>.from(_controllers);
    for (final ctrl in controllers) {
      try {
        await _apply(ctrl, update);
      } catch (e) {/* log error */}
    }
    // Also queue for future WebViews
    if (controllers.isEmpty) _updateQueue.add(update);
  }

  /// Run JavaScript in the WebView and return the result.
  Future<String> evalJs(String code) async {
    final ctrl = _controllers.isEmpty ? null : _controllers.first;
    if (ctrl == null) return jsonEncode({'error': '画布未就绪'});
    try {
      final result = await ctrl.runJavaScriptReturningResult(code);
      return jsonEncode({'result': result.toString()});
    } catch (e) {
      return jsonEncode({'error': e.toString()});
    }
  }

  /// Clear all canvas content — reset to blank transparent page.
  Future<void> clearCanvas() async {
    _lastHtml = null;
    // A render requested before the PlatformView became ready may still be in
    // this queue. Clearing the visible state without clearing the queue can
    // replay stale HTML when a later conversation mounts a new WebView.
    _updateQueue.clear();
    hasContent.value = false;
    revision.value++;
    try {
      await DB.setConfig('canvas_html', '');
    } catch (_) {}
    final controllers = List<WebViewController>.from(_controllers);
    for (final ctrl in controllers) {
      try {
        await ctrl.runJavaScript("document.getElementById('c').innerHTML='';");
        await ctrl.loadHtmlString(blankPage);
      } catch (_) {}
    }
  }

  Future<void> _apply(WebViewController ctrl, _HtmlUpdate update) async {
    final bytes = utf8.encode(update.html);
    final b64 = base64Encode(bytes);
    if (update.mode == 'replace') {
      // Use JS injection to avoid loadHtmlString flash on Android.
      // Clear #c and inject new content without navigating.
      final escaped = update.html
          .replaceAll(r'\', r'\\')
          .replaceAll(r'`', r'\`')
          .replaceAll(r'$', r'\$');
      try {
        await ctrl.runJavaScript('''
(function(){
  var c=document.getElementById('c')||document.body;
  c.innerHTML=`$escaped`;
})();
''');
      } catch (_) {
        // Fallback: if JS injection fails, use loadHtmlString
        final html = _wrapPage(update.html);
        await ctrl.loadHtmlString(html);
      }
    } else {
      // Append: use base64 to avoid template-literal escaping pitfalls
      await ctrl.runJavaScript('''
(function(){
  var d=document.createElement('div');
  d.innerHTML=atob("$b64");
  var c=document.getElementById('c')||document.body;
  c.appendChild(d);
})();
''');
    }
  }

  /// If the HTML doesn't look like a full page, wrap it.
  String _wrapPage(String html) {
    final trimmed = html.trim();
    if (trimmed.startsWith('<!DOCTYPE') || trimmed.startsWith('<html')) {
      return html;
    }
    return '<!DOCTYPE html><html><head>'
        '<meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">'
        '<style>'
        '*{margin:0;padding:0;box-sizing:border-box}'
        'html,body{width:100%;height:100%;background:transparent;overflow:hidden}'
        '#c{position:fixed;top:0;left:0;width:100%;height:100%}'
        '</style>'
        '</head><body>$html'
        '</body></html>';
  }
}

class _HtmlUpdate {
  final String html;
  final String mode;
  const _HtmlUpdate({required this.html, this.mode = 'replace'});
}

// ═══════════════════════════════════════════════
// Widget
// ═══════════════════════════════════════════════

class WebViewCanvas extends StatefulWidget {
  const WebViewCanvas({super.key});

  @override
  State<WebViewCanvas> createState() => _WebViewCanvasState();
}

class _WebViewCanvasState extends State<WebViewCanvas>
    with WidgetsBindingObserver {
  // Creating a WebViewController immediately starts Chromium on Android even
  // when the canvas is empty. Keep it genuinely lazy: a normal chat must not
  // pay the ~100 MB WebView process cost or create a PlatformView surface.
  WebViewController? _ctrl;
  bool _loaded = false;
  bool _shouldRender = false;
  Uint8List? _screenshot; // WebView 渲染完截图，之后显示静态图零 GPU 开销
  Timer? _renderWatchdog;
  int _renderEpoch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WebViewCanvasController().revision.addListener(_onRevision);
    _loadStartup();
  }

  WebViewController _ensureController() {
    final existing = _ctrl;
    if (existing != null) return existing;

    late final WebViewController created;
    created = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) async {
            if (!mounted || !identical(_ctrl, created)) return;
            WebViewCanvasController()._onReady(created);
            // 渲染完成 → 截图 → 切静态显示，销毁 WebView 的 PlatformView 开销
            final epoch = _renderEpoch;
            await _captureAndFreeze(epoch);
          },
        ),
      );
    _ctrl = created;
    return created;
  }

  void _releaseController([WebViewController? expected]) {
    final controller = _ctrl;
    if (controller == null) return;
    // A delayed unmount callback must never release a newer controller that was
    // created by a subsequent render_html revision.
    if (expected != null && !identical(controller, expected)) return;
    WebViewCanvasController()._onDispose(controller);
    _ctrl = null;
  }

  void _releaseControllerAfterFrame(
    int epoch,
    WebViewController controller,
  ) {
    // WebViewWidget must first disappear from the Flutter tree. Releasing the
    // Dart controller in the same setState call can leave a stale Android
    // PlatformView surface alive on some MIUI compositors.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || epoch != _renderEpoch) return;
      _releaseController(controller);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _renderWatchdog?.cancel();
    WebViewCanvasController().revision.removeListener(_onRevision);
    _releaseController();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _hidePlatformView(_renderEpoch);
    }
  }

  /// 截取 WebView 画面，存入 _screenshot，然后隐藏 WebView（触发 build 返回 Image）。
  Future<void> _captureAndFreeze(int epoch) async {
    if (!mounted) return;
    final controller = _ctrl;
    if (controller == null) return;
    try {
      // 等一小段让 CSS 动画/过渡完成
      await Future.delayed(const Duration(milliseconds: 220));
      if (!mounted || epoch != _renderEpoch) return;
      // JS 方案：查找 canvas 元素获取 dataURL，回退到截取 body
      final result = await controller.runJavaScriptReturningResult('''
        (function(){
          var c=document.querySelector('canvas');
          if(c){ return c.toDataURL('image/png'); }
          return null;
        })()
      ''').timeout(const Duration(milliseconds: 900));
      if (!mounted || epoch != _renderEpoch) return;
      final dataUrl =
          result is String ? result.replaceAll(RegExp(r'^"|"$'), '') : '';
      if (dataUrl.startsWith('data:image')) {
        final base64 = dataUrl.split(',').last;
        final bytes = base64Decode(base64);
        if (mounted) {
          setState(() {
            _screenshot = bytes;
            _shouldRender = false;
          });
          _renderWatchdog?.cancel();
          _releaseControllerAfterFrame(epoch, controller);
        }
        return;
      }
      // DOM-only HTML cannot be captured through webview_flutter. Keeping an
      // Android PlatformView alive behind Flutter content can render as a black
      // overlay above the UI, so fail safe: remove WebView instead of risking
      // black screen. Canvas-based render_html keeps working via dataURL above.
      _hidePlatformView(epoch);
    } catch (_) {
      // 截图不可用时也移除 WebView，避免黑屏覆盖聊天层。
      _hidePlatformView(epoch);
    }
  }

  void _hidePlatformView(int epoch) {
    if (!mounted || epoch != _renderEpoch) return;
    final controller = _ctrl;
    _renderWatchdog?.cancel();
    if (_shouldRender) setState(() => _shouldRender = false);
    if (controller != null) {
      _releaseControllerAfterFrame(epoch, controller);
    }
  }

  void _beginRender(String html) {
    if (!mounted) return;
    final controller = _ensureController();
    final epoch = ++_renderEpoch;
    _renderWatchdog?.cancel();
    setState(() {
      _loaded = true;
      _screenshot = null;
      _shouldRender = true;
    });

    // 无论 WebView 回调或 JS 是否卡住，原生视图最多存活 1.8 秒。
    // 这是防止 Android PlatformView 永久覆盖 Flutter UI 的最终保险。
    _renderWatchdog = Timer(
      const Duration(milliseconds: 1800),
      () => _hidePlatformView(epoch),
    );

    unawaited(
      controller
          .loadHtmlString(WebViewCanvasController()._wrapPage(html))
          .timeout(const Duration(milliseconds: 1200))
          .catchError((_) => _hidePlatformView(epoch)),
    );
  }

  void _onRevision() {
    if (!mounted) return;
    final canvas = WebViewCanvasController();
    if (!canvas.hasContent.value) {
      _onHasContent();
      return;
    }
    _beginRender(canvas._lastHtml ?? WebViewCanvasController.blankPage);
  }

  void _onHasContent() {
    if (!mounted) return;
    final ctrl = WebViewCanvasController();
    if (!ctrl.hasContent.value) {
      // 清空画布后彻底移除 PlatformView，避免透明 WebView 在 Android 上黑屏覆盖。
      setState(() {
        _renderWatchdog?.cancel();
        _renderEpoch++;
        _screenshot = null;
        _shouldRender = false;
        _loaded = true;
      });
      final controller = _ctrl;
      if (controller != null) {
        // Let the frame that removed WebViewWidget reach Android before
        // dropping the controller. This is the critical MIUI black-layer fix.
        _releaseControllerAfterFrame(_renderEpoch, controller);
      }
      return;
    }
    _beginRender(ctrl._lastHtml ?? WebViewCanvasController.blankPage);
  }

  Future<void> _loadStartup() async {
    String html;
    try {
      html = await WebViewCanvasController().getStartupHtml();
    } catch (_) {
      html = WebViewCanvasController.blankPage;
    }
    final isBlank = html == WebViewCanvasController.blankPage;
    if (isBlank) {
      WebViewCanvasController().hasContent.value = false;
      if (mounted) setState(() => _loaded = true);
    } else {
      WebViewCanvasController().hasContent.value = true;
      if (mounted) _beginRender(html);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 有截图 → 显示静态图片，零 PlatformView 开销
    if (_screenshot != null) {
      return SizedBox.expand(
        child: Image.memory(_screenshot!, fit: BoxFit.cover),
      );
    }
    // 没有内容 → 不渲染
    if (!_loaded || !_shouldRender) return const SizedBox.shrink();
    final controller = _ctrl;
    if (controller == null) return const SizedBox.shrink();
    // 正在渲染 → WebView（短暂存在）。必须填满父 Stack，给 Android
    // PlatformView tight constraints；裸 WebViewWidget 会偶发 0 尺寸/黑层覆盖。
    return ClipRect(
      child: Opacity(
        // WebView 只作为短时离屏渲染器。保持极低但非零透明度，确保
        // Android 纹理继续产出帧，同时不会把初始化黑底/灰底闪到聊天 UI。
        opacity: 0.01,
        child: SizedBox.expand(child: WebViewWidget(controller: controller)),
      ),
    );
  }
}
