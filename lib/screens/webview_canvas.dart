/// WebView Canvas — Solvhen's HTML playground.
///
/// Replaces the complex Flutter visual layer with a single WebView.
/// Solvhen controls it via the `render_html` tool.
/// HTML content persists across app restarts (saved to DB config).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/database_service.dart';

// ═══════════════════════════════════════════════
// Controller — singleton, tool talks to this
// ═══════════════════════════════════════════════

class WebViewCanvasController {
  static final WebViewCanvasController _instance = WebViewCanvasController._();
  factory WebViewCanvasController() => _instance;
  WebViewCanvasController._();

  WebViewController? _webCtrl;
  final _updateQueue = <_HtmlUpdate>[];
  bool _ready = false;
  String? _lastError;
  String? _lastHtml; // cached for persistence

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
      final saved = config['canvas_html'] as String?;
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
    _webCtrl = ctrl;
    _ready = true;
    _flushQueue();
  }

  void _onDispose() {
    _webCtrl = null;
    _ready = false;
    _updateQueue.clear();
    _lastError = null;
    _lastHtml = null;
  }

  Future<void> _flushQueue() async {
    if (_updateQueue.isEmpty) return;
    final batch = List<_HtmlUpdate>.from(_updateQueue);
    _updateQueue.clear();

    for (final u in batch) {
      try {
        await _apply(u);
      } catch (e) {
        _lastError = e.toString();
      }
    }
  }

  Future<void> renderHtml(String html, {String mode = 'replace'}) async {
    // Persist immediately so restarts don't lose the canvas
    if (mode == 'replace') {
      _saveHtml(html);
    }

    final update = _HtmlUpdate(html: html, mode: mode);
    if (_ready && _webCtrl != null) {
      try {
        await _apply(update);
      } catch (e) {
        _lastError = e.toString();
      }
    } else {
      _updateQueue.add(update);
    }
  }

  /// Run JavaScript in the WebView and return the result.
  Future<String> evalJs(String code) async {
    if (_webCtrl == null) return jsonEncode({'error': '画布未就绪'});
    try {
      final result = await _webCtrl!.runJavaScriptReturningResult(code);
      return jsonEncode({'result': result.toString()});
    } catch (e) {
      return jsonEncode({'error': e.toString()});
    }
  }

  Future<void> _apply(_HtmlUpdate update) async {
    final ctrl = _webCtrl!;
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

  @override
  void initState() {
    super.initState();
    _ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            WebViewCanvasController()._onReady(_ctrl);
          },
        ),
      );

    // Load persisted HTML on startup
    _loadStartup();
  }

  Future<void> _loadStartup() async {
    String html;
    try {
      html = await WebViewCanvasController().getStartupHtml();
    } catch (_) {
      html = WebViewCanvasController.blankPage;
    }
    if (mounted) {
      _ctrl.loadHtmlString(html);
      _loaded = true;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    WebViewCanvasController()._onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    return WebViewWidget(controller: _ctrl);
  }
}
