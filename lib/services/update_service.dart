// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// OTA 更新服务 — 检查版本 → 下载 APK → 提示安装
// ═══════════════════════════════════════════════════════════════
library;

import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../core/security/update_manifest.dart';
import 'android_package_verifier.dart';

export '../core/security/update_manifest.dart';

/// Check for updates from the configured OTA server.
/// Returns [UpdateInfo] if a newer version is available, null otherwise.
Future<UpdateInfo?> checkForUpdate({
  required String updateUrl,
  required int currentVersionCode,
}) async {
  final baseUrl = requireOfficialUpdateBaseUrl(updateUrl);
  try {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ));
    final resp = await dio.get('$baseUrl/latest.json');
    if (resp.statusCode != 200) return null;

    if (resp.data is! Map) {
      throw const FormatException('更新清单格式无效');
    }
    final info = UpdateInfo.fromJson(
      Map<String, dynamic>.from(resp.data as Map),
    );
    info.validate();
    if (!await verifyUpdateManifestSignature(info)) {
      throw const FormatException('更新清单 Ed25519 签名验证失败');
    }
    if (info.versionCode > currentVersionCode) {
      return info;
    }
    return null;
  } on FormatException {
    rethrow;
  } on StateError {
    rethrow;
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
  info.validate();
  if (!await verifyUpdateManifestSignature(info)) {
    throw const FormatException('更新清单 Ed25519 签名验证失败');
  }
  final dir = await getExternalStorageDirectory() ??
      await getApplicationDocumentsDirectory();
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

  await verifyDownloadedUpdate(info, file.path, deleteOnFailure: true);

  return file.path;
}

/// Re-validates file bytes and Android package identity. This is called both
/// after download and immediately before opening the installer to close the
/// replace-between-check-and-use window.
Future<void> verifyDownloadedUpdate(
  UpdateInfo info,
  String filePath, {
  bool deleteOnFailure = false,
}) async {
  final file = File(filePath);
  try {
    if (!await file.exists()) {
      throw const FormatException('更新 APK 不存在');
    }
    final actualHash = sha256.convert(await file.readAsBytes()).toString();
    if (actualHash.toLowerCase() != info.sha256.toLowerCase()) {
      throw const FormatException('APK SHA-256 校验失败');
    }
    final identity = await AndroidPackageVerifier.verify(filePath);
    if (identity.packageName != info.packageName) {
      throw const FormatException('APK 实际包名与更新清单不一致');
    }
    if (identity.archiveCertificateSha256.toLowerCase() !=
        info.signingCertificateSha256.toLowerCase()) {
      throw const FormatException('APK 签名证书与更新清单不一致');
    }
    if (!identity.matchesInstalledCertificate) {
      throw const FormatException('APK 签名证书与当前安装版本不一致');
    }
  } catch (_) {
    if (deleteOnFailure && await file.exists()) await file.delete();
    rethrow;
  }
}

/// Open the APK file with system installer after a final identity check.
Future<bool> installApk(String filePath, UpdateInfo info) async {
  try {
    await verifyDownloadedUpdate(info, filePath, deleteOnFailure: true);
    final result = await OpenFilex.open(
      filePath,
      type: 'application/vnd.android.package-archive',
    );
    return result.type == ResultType.done;
  } catch (e) {
    debugPrint('[Update] install failed: $e');
    return false;
  }
}
