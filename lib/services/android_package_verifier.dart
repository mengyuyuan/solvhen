import 'package:flutter/services.dart';

class AndroidPackageIdentity {
  const AndroidPackageIdentity({
    required this.packageName,
    required this.archiveCertificateSha256,
    required this.installedCertificateSha256,
    required this.matchesInstalledCertificate,
  });

  final String packageName;
  final String archiveCertificateSha256;
  final String installedCertificateSha256;
  final bool matchesInstalledCertificate;
}

class AndroidPackageVerifier {
  static const _channel = MethodChannel('solvhen/system');

  static Future<AndroidPackageIdentity> verify(String filePath) async {
    final raw = await _channel.invokeMethod<dynamic>(
      'verifyApkIdentity',
      {'filePath': filePath},
    );
    if (raw is! Map) {
      throw const FormatException('Android 未返回 APK 身份信息');
    }
    final value = Map<String, dynamic>.from(raw);
    if (value['error'] != null) {
      throw FormatException('APK 身份读取失败：${value['error']}');
    }
    final packageName = value['packageName'] as String? ?? '';
    final archive = value['archiveCertificateSha256'] as String? ?? '';
    final installed = value['installedCertificateSha256'] as String? ?? '';
    if (packageName.isEmpty || archive.isEmpty || installed.isEmpty) {
      throw const FormatException('APK 身份信息不完整');
    }
    return AndroidPackageIdentity(
      packageName: packageName,
      archiveCertificateSha256: archive,
      installedCertificateSha256: installed,
      matchesInstalledCertificate: value['matchesInstalledCertificate'] == true,
    );
  }
}
