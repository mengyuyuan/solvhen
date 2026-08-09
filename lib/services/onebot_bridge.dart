// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// OneBot 桥接服务 — 起 WebSocket 服务接收 NapCatQQ 等 OneBot 客户端连接
// 收到的消息自动走 Solvhen AI 回复，像 Hermes 一样接入 QQ/微信
// ═══════════════════════════════════════════════════════════════

library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// OneBot 消息事件
class OneBotMessage {
  final String postType; // "message"
  final String messageType; // "private" | "group"
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
      rawMessage:
          json['raw_message'] as String? ?? json['message'] as String? ?? '',
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
  final _messageRoutes = <int, WebSocket>{};
  final _rateWindows = <WebSocket, Queue<DateTime>>{};
  bool _running = false;
  int _port = 0;
  int _pendingUpgrades = 0;
  int _inFlightMessages = 0;

  /// 收到 QQ/微信消息时的回调
  Future<void> Function(OneBotMessage msg, String platform)? onMessage;

  /// 状态变化回调（供UI显示连接状态）
  void Function(bool running, int clientCount)? onStatusChange;

  bool get isRunning => _running;
  int get clientCount => _clients.length;
  int get port => _port;

  /// 启动 WebSocket 服务，监听指定端口（默认 13579）
  Future<bool> start({
    int port = 13579,
    required String accessToken,
    bool allowInsecureLan = false,
  }) async {
    if (_running) return true;
    if (!allowInsecureLan || accessToken.length < 32) {
      debugPrint('[OneBot] refused insecure or tokenless startup');
      return false;
    }
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _port = _server!.port;
      _running = true;
      onStatusChange?.call(true, 0);
      debugPrint('[OneBot] server started on port $port');

      _server!.listen((HttpRequest request) async {
        if (request.uri.path == '/onebot' || request.uri.path == '/') {
          final remote = request.connectionInfo?.remoteAddress;
          if (remote == null || !_isPrivateAddress(remote)) {
            request.response
              ..statusCode = HttpStatus.forbidden
              ..write('LAN connections only');
            await request.response.close();
            return;
          }
          // Tokens in URLs leak into access logs and proxy history. OneBot
          // clients must use `Authorization: Bearer <token>`.
          final supplied = _bearerToken(request) ?? '';
          if (!_constantTimeEquals(supplied, accessToken)) {
            request.response
              ..statusCode = HttpStatus.unauthorized
              ..write('Invalid access token');
            await request.response.close();
            return;
          }
          if (_clients.length + _pendingUpgrades >= 2) {
            request.response
              ..statusCode = HttpStatus.serviceUnavailable
              ..write('Too many clients');
            await request.response.close();
            return;
          }
          _pendingUpgrades++;
          try {
            final socket = await WebSocketTransformer.upgrade(request);
            _handleClient(socket);
          } catch (e) {
            debugPrint('[OneBot] upgrade error: $e');
          } finally {
            _pendingUpgrades = (_pendingUpgrades - 1).clamp(0, 2);
          }
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
    _messageRoutes.clear();
    _rateWindows.clear();
    await _server?.close().catchError((_) {});
    _server = null;
    onStatusChange?.call(false, 0);
    debugPrint('[OneBot] server stopped');
  }

  /// 重启服务（换端口）
  Future<bool> restart({
    int port = 13579,
    required String accessToken,
    bool allowInsecureLan = false,
  }) async {
    await stop();
    return start(
      port: port,
      accessToken: accessToken,
      allowInsecureLan: allowInsecureLan,
    );
  }

  void _handleClient(WebSocket socket) {
    _clients.add(socket);
    _rateWindows[socket] = Queue<DateTime>();
    onStatusChange?.call(true, _clients.length);
    debugPrint('[OneBot] client connected (total: ${_clients.length})');

    socket.listen(
      (data) {
        if (data is! String || utf8.encode(data).length > 64 * 1024) {
          socket.close(WebSocketStatus.messageTooBig, 'Message too large');
          return;
        }
        unawaited(_onData(socket, data));
      },
      onError: (e) => debugPrint('[OneBot] socket error: $e'),
      onDone: () {
        _clients.remove(socket);
        _rateWindows.remove(socket);
        _messageRoutes.removeWhere((_, route) => identical(route, socket));
        onStatusChange?.call(_running, _clients.length);
        debugPrint('[OneBot] client disconnected (left: ${_clients.length})');
      },
      cancelOnError: true,
    );
  }

  Future<void> _onData(WebSocket socket, String data) async {
    try {
      if (!_consumeRateLimit(socket)) {
        socket.close(WebSocketStatus.policyViolation, 'Rate limit exceeded');
        return;
      }
      final json = jsonDecode(data) as Map<String, dynamic>;
      final postType = json['post_type'] as String?;

      if (postType == 'message') {
        final msg = OneBotMessage.fromJson(json);
        if (msg.rawMessage.isEmpty ||
            msg.rawMessage.length > 8000 ||
            msg.userId <= 0 ||
            !const {'private', 'group'}.contains(msg.messageType) ||
            (msg.messageType == 'group' && msg.groupId == null)) {
          return;
        }
        if (_inFlightMessages >= 2) {
          debugPrint('[OneBot] message dropped: busy');
          return;
        }
        if (_messageRoutes.length >= 100) {
          _messageRoutes.remove(_messageRoutes.keys.first);
        }
        _messageRoutes[msg.messageId] = socket;
        final platform = _guessPlatform(socket);
        debugPrint('[OneBot] message accepted from $platform');
        final callback = onMessage;
        if (callback != null) {
          _inFlightMessages++;
          try {
            await callback(msg, platform);
          } finally {
            _inFlightMessages--;
            _messageRoutes.remove(msg.messageId);
          }
        }
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
    int? sourceMessageId,
  }) async {
    if (_clients.isEmpty) {
      debugPrint('[OneBot] no clients to send');
      return false;
    }

    final action =
        messageType == 'group' ? 'send_group_msg' : 'send_private_msg';
    final params = <String, dynamic>{
      if (messageType == 'group') 'group_id': groupId,
      'user_id': userId,
      'message': message.length > 8000 ? message.substring(0, 8000) : message,
    };

    final payload = jsonEncode({
      'action': action,
      'params': params,
    });

    final routed =
        sourceMessageId == null ? null : _messageRoutes.remove(sourceMessageId);
    final targets = routed != null ? <WebSocket>[routed] : _clients.take(1);
    var ok = false;
    for (final client in targets) {
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

  String? _bearerToken(HttpRequest request) {
    final value = request.headers.value(HttpHeaders.authorizationHeader);
    if (value == null || !value.startsWith('Bearer ')) return null;
    return value.substring(7).trim();
  }

  bool _constantTimeEquals(String a, String b) {
    var diff = a.length ^ b.length;
    final max = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < max; i++) {
      final ac = i < a.length ? a.codeUnitAt(i) : 0;
      final bc = i < b.length ? b.codeUnitAt(i) : 0;
      diff |= ac ^ bc;
    }
    return diff == 0;
  }

  bool _isPrivateAddress(InternetAddress address) {
    if (address.isLoopback) return true;
    final raw = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && raw.length == 4) {
      return raw[0] == 10 ||
          (raw[0] == 172 && raw[1] >= 16 && raw[1] <= 31) ||
          (raw[0] == 192 && raw[1] == 168);
    }
    if (address.type == InternetAddressType.IPv6 && raw.length == 16) {
      return (raw[0] & 0xFE) == 0xFC ||
          (raw[0] == 0xFE && (raw[1] & 0xC0) == 0x80);
    }
    return false;
  }

  bool _consumeRateLimit(WebSocket socket) {
    final now = DateTime.now();
    final window = _rateWindows.putIfAbsent(socket, Queue<DateTime>.new);
    final cutoff = now.subtract(const Duration(minutes: 1));
    while (window.isNotEmpty && window.first.isBefore(cutoff)) {
      window.removeFirst();
    }
    if (window.length >= 20) return false;
    window.addLast(now);
    return true;
  }
}
