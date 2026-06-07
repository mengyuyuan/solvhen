// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// OTA 更新服务 — 检查版本 → 下载 APK → 提示安装
// ═══════════════════════════════════════════════════════════════
library;

import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

/// Update info from server.
class UpdateInfo {
  final String version;
  final int versionCode;
  final String url;
  final String? changelog;
  const UpdateInfo({
    required this.version,
    required this.versionCode,
    required this.url,
    this.changelog,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) => UpdateInfo(
    version: json['version'] as String? ?? '',
    versionCode: json['versionCode'] as int? ?? 0,
    url: json['url'] as String? ?? '',
    changelog: json['changelog'] as String?,
  );
}

/// Check for updates from the configured OTA server.
/// Returns [UpdateInfo] if a newer version is available, null otherwise.
Future<UpdateInfo?> checkForUpdate({
  required String updateUrl,
  required int currentVersionCode,
}) async {
  try {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ));
    final resp = await dio.get('$updateUrl/latest.json');
    if (resp.statusCode != 200) return null;

    final info = UpdateInfo.fromJson(resp.data);
    if (info.versionCode > currentVersionCode) {
      return info;
    }
    return null;
  } catch (e) {
    debugPrint('[Update] check failed: $e');
    return null;
  }
}

/// Download the APK and return the local file path.
/// Shows progress via [onProgress] callback (0.0-1.0).
Future<String> downloadUpdate(
  UpdateInfo info, {
  void Function(double progress)? onProgress,
}) async {
  final dir = await getExternalStorageDirectory()
      ?? await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/solvhen_update.apk');
  if (await file.exists()) await file.delete();

  final dio = Dio();
  await dio.download(
    info.url,
    file.path,
    onReceiveProgress: (count, total) {
      if (total > 0) onProgress?.call(count / total);
    },
  );

  return file.path;
}

/// Open the APK file with system installer.
Future<bool> installApk(String filePath) async {
  try {
    final result = await OpenFilex.open(filePath,
      type: 'application/vnd.android.package-archive',
    );
    return result.type == ResultType.done;
  } catch (e) {
    debugPrint('[Update] install failed: $e');
    return false;
  }
}
