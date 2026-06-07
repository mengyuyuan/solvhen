// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// WebView画布——Android PlatformView渲染HTML画布，AI可动态绘制视觉效果
// ═══════════════════════════════════════════════════════════════

library;

///
/// Replaces the complex Flutter visual layer with a single WebView.
/// Solvhen controls it via the `render_html` tool.
/// HTML content persists across app restarts (saved to DB config).

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

  /// Load persisted HTML from DB. Returns null if none saved.
  Future<String?> _loadSavedHtml() async {
    if (_lastHtml != null) return _lastHtml;
    try {
      final config = await DB.getConfig();
      final saved = config['canvas_html'];
      if (saved != null && saved.isNotEmpty) {
        _lastHtml = saved;
        return saved;
      }
    } catch (_) {}
    return null;
  }

  /// Persist current HTML to DB for survival across restarts.
  Future<void> _saveHtml(String html) async {
    _lastHtml = html;
    try {
      await DB.setConfig('canvas_html', html);
    } catch (_) {}
  }

  /// Get the HTML to load on startup: saved canvas or blank page.
  Future<String> getStartupHtml() async {
    final saved = await _loadSavedHtml();
    return saved ?? blankPage;
  }

  void _onReady(WebViewController ctrl) {
    _controllers.add(ctrl);
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
        try { await _apply(ctrl, u); } catch (e) { /* log error */ }
      }
    }
  }

  Future<void> renderHtml(String html, {String mode = 'replace'}) async {
    if (mode == 'replace') _saveHtml(html);

    // 通知所有 WebViewCanvas widget：画布有内容，需要渲染
    hasContent.value = true;

    final update = _HtmlUpdate(html: html, mode: mode);
    // Broadcast to all active WebViews
    final controllers = List<WebViewController>.from(_controllers);
    for (final ctrl in controllers) {
      try { await _apply(ctrl, update); } catch (e) { /* log error */ }
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
    try { await DB.setConfig('canvas_html', ''); } catch (_) {}
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
        '</head><body>'
        '${html}'
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

class _WebViewCanvasState extends State<WebViewCanvas> {
  late final WebViewController _ctrl;
  bool _loaded = false;
  bool _shouldRender = false;
  Uint8List? _screenshot; // WebView 渲染完截图，之后显示静态图零 GPU 开销

  @override
  void initState() {
    super.initState();
    _ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) async {
            WebViewCanvasController()._onReady(_ctrl);
            // 渲染完成 → 截图 → 切静态显示，销毁 WebView 的 PlatformView 开销
            await _captureAndFreeze();
          },
        ),
      );

    WebViewCanvasController().hasContent.addListener(_onHasContent);
    _loadStartup();
  }

  @override
  void dispose() {
    WebViewCanvasController().hasContent.removeListener(_onHasContent);
    WebViewCanvasController()._onDispose(_ctrl);
    super.dispose();
  }

  /// 截取 WebView 画面，存入 _screenshot，然后隐藏 WebView（触发 build 返回 Image）。
  Future<void> _captureAndFreeze() async {
    if (!mounted) return;
    try {
      // 等一小段让 CSS 动画/过渡完成
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      // JS 方案：查找 canvas 元素获取 dataURL，回退到截取 body
      final result = await _ctrl.runJavaScriptReturningResult('''
        (function(){
          var c=document.querySelector('canvas');
          if(c){ return c.toDataURL('image/png'); }
          return null;
        })()
      ''');
      if (result is String && result.startsWith('data:image')) {
        final base64 = result.split(',').last;
        final bytes = base64Decode(base64);
        if (mounted) setState(() {
          _screenshot = bytes;
          _shouldRender = false;
        });
      }
    } catch (_) {
      // 截图不可用，保持 WebView 显示
    }
  }

  void _onHasContent() {
    if (!mounted) return;
    final ctrl = WebViewCanvasController();
    if (ctrl.hasContent.value) {
      // 新内容 → 清旧截图，重新渲染 WebView
      _screenshot = null;
      final html = ctrl._lastHtml ?? WebViewCanvasController.blankPage;
      _ctrl.loadHtmlString(html);
      if (!_shouldRender) setState(() => _shouldRender = true);
    }
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
      if (mounted) {
        _ctrl.loadHtmlString(html);
        _loaded = true;
        _shouldRender = true;
        if (mounted) setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 有截图 → 显示静态图片，零 PlatformView 开销
    if (_screenshot != null) {
      return Positioned.fill(
        child: Image.memory(_screenshot!, fit: BoxFit.cover),
      );
    }
    // 没有内容 → 不渲染
    if (!_loaded || !_shouldRender) return const SizedBox.shrink();
    // 正在渲染 → WebView（短暂存在）
    return WebViewWidget(controller: _ctrl);
  }
}
