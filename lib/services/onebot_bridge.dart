// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// OneBot 桥接服务 — 起 WebSocket 服务接收 NapCatQQ 等 OneBot 客户端连接
// 收到的消息自动走 Solvhen AI 回复，像 Hermes 一样接入 QQ/微信
// ═══════════════════════════════════════════════════════════════

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// OneBot 消息事件
class OneBotMessage {
  final String postType;       // "message"
  final String messageType;    // "private" | "group"
  final int userId;
  final int? groupId;
  final String rawMessage;
  final int messageId;
  final String? senderNickname;

  const OneBotMessage({
    required this.postType,
    required this.messageType,
    required this.userId,
    this.groupId,
    required this.rawMessage,
    required this.messageId,
    this.senderNickname,
  });

  factory OneBotMessage.fromJson(Map<String, dynamic> json) {
    return OneBotMessage(
      postType: json['post_type'] as String? ?? '',
      messageType: json['message_type'] as String? ?? 'private',
      userId: json['sender']?['user_id'] as int? ?? 0,
      groupId: json['group_id'] as int?,
      rawMessage: json['raw_message'] as String? ?? json['message'] as String? ?? '',
      messageId: json['message_id'] as int? ?? 0,
      senderNickname: json['sender']?['nickname'] as String?,
    );
  }
}

/// OneBot 桥接服务 — 单例
/// 启动后监听 WebSocket，NapCatQQ 等 OneBot 客户端可连接
/// 收到消息时回调 onMessage，对方可通过 sendReply 回复
class OneBotBridge {
  static final OneBotBridge _instance = OneBotBridge._();
  factory OneBotBridge() => _instance;
  OneBotBridge._();

  HttpServer? _server;
  final _clients = <WebSocket>[];
  bool _running = false;
  int _port = 0;

  /// 收到 QQ/微信消息时的回调
  void Function(OneBotMessage msg, String platform)? onMessage;

  /// 状态变化回调（供UI显示连接状态）
  void Function(bool running, int clientCount)? onStatusChange;

  bool get isRunning => _running;
  int get clientCount => _clients.length;
  int get port => _port;

  /// 启动 WebSocket 服务，监听指定端口（默认 13579）
  Future<bool> start({int port = 13579}) async {
    if (_running) return true;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _port = port;
      _running = true;
      onStatusChange?.call(true, 0);
      debugPrint('[OneBot] server started on port $port');

      _server!.listen((HttpRequest request) {
        if (request.uri.path == '/onebot' || request.uri.path == '/') {
          WebSocketTransformer.upgrade(request).then(_handleClient,
            onError: (e) => debugPrint('[OneBot] upgrade error: $e'));
        } else {
          request.response
            ..statusCode = 404
            ..close();
        }
      });
      return true;
    } catch (e) {
      debugPrint('[OneBot] failed to start: $e');
      _running = false;
      return false;
    }
  }

  /// 停止服务
  Future<void> stop() async {
    _running = false;
    for (final client in List<WebSocket>.from(_clients)) {
      await client.close().catchError((_) {});
    }
    _clients.clear();
    await _server?.close().catchError((_) {});
    _server = null;
    onStatusChange?.call(false, 0);
    debugPrint('[OneBot] server stopped');
  }

  /// 重启服务（换端口）
  Future<bool> restart({int port = 13579}) async {
    await stop();
    return start(port: port);
  }

  void _handleClient(WebSocket socket) {
    _clients.add(socket);
    onStatusChange?.call(true, _clients.length);
    debugPrint('[OneBot] client connected (total: ${_clients.length})');

    socket.listen(
      (data) => _onData(socket, data as String),
      onError: (e) => debugPrint('[OneBot] socket error: $e'),
      onDone: () {
        _clients.remove(socket);
        onStatusChange?.call(_running, _clients.length);
        debugPrint('[OneBot] client disconnected (left: ${_clients.length})');
      },
      cancelOnError: true,
    );
  }

  void _onData(WebSocket socket, String data) {
    try {
      final json = jsonDecode(data) as Map<String, dynamic>;
      final postType = json['post_type'] as String?;

      if (postType == 'message') {
        final msg = OneBotMessage.fromJson(json);
        final platform = _guessPlatform(socket);
        debugPrint('[OneBot] msg from $platform: ${msg.rawMessage}');
        onMessage?.call(msg, platform);
      }
      // 忽略其他类型事件（notice, request, meta_event 等）
    } catch (e) {
      debugPrint('[OneBot] parse error: $e');
    }
  }

  /// 发送回复消息
  Future<bool> sendReply({
    required String messageType,
    required int userId,
    int? groupId,
    required String message,
  }) async {
    if (_clients.isEmpty) {
      debugPrint('[OneBot] no clients to send');
      return false;
    }

    final action = messageType == 'group' ? 'send_group_msg' : 'send_private_msg';
    final params = <String, dynamic>{
      if (messageType == 'group') 'group_id': groupId,
      'user_id': userId,
      'message': message,
    };

    final payload = jsonEncode({
      'action': action,
      'params': params,
    });

    var ok = false;
    for (final client in _clients) {
      try {
        client.add(payload);
        ok = true;
      } catch (e) {
        debugPrint('[OneBot] send error: $e');
      }
    }
    return ok;
  }

  /// 通过客户端 source 猜测平台
  String _guessPlatform(WebSocket socket) {
    // NapCatQQ 连接时会带自定义 header，OneBot 协议没有标准方式区分
    // 默认当作 QQ，后续可通过配置指定
    return 'QQ';
  }
}
