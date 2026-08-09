import 'dart:convert';

import 'package:cryptography/cryptography.dart';

const officialUpdateHost = 'ota.sywy.app';
const officialUpdateBaseUrl = 'https://$officialUpdateHost';
const solvhenPackageName = 'com.sywy.solvhen';
const officialUpdatePublicKeyBase64 =
    String.fromEnvironment('SOLVHEN_OTA_PUBLIC_KEY');

bool get hasOfficialUpdatePublicKey {
  try {
    return base64Decode(officialUpdatePublicKeyBase64).length == 32;
  } catch (_) {
    return false;
  }
}

String? normalizeOfficialUpdateBaseUrl(String? value) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.host.toLowerCase() != officialUpdateHost ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.hasPort && uri.port != 443)) {
    return null;
  }
  final path = uri.path.replaceAll(RegExp(r'/+$'), '');
  return Uri(
    scheme: 'https',
    host: officialUpdateHost,
    path: path,
  ).toString().replaceAll(RegExp(r'/+$'), '');
}

String requireOfficialUpdateBaseUrl(String value) {
  final normalized = normalizeOfficialUpdateBaseUrl(value);
  if (normalized == null) {
    throw const FormatException('OTA 仅允许官方 HTTPS 地址 ota.sywy.app');
  }
  return normalized;
}

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.versionCode,
    required this.url,
    required this.sha256,
    required this.packageName,
    required this.signingCertificateSha256,
    required this.signature,
    this.changelog,
  });

  final String version;
  final int versionCode;
  final String url;
  final String sha256;
  final String packageName;
  final String signingCertificateSha256;
  final String signature;
  final String? changelog;

  factory UpdateInfo.fromJson(Map<String, dynamic> json) => UpdateInfo(
        version: json['version'] as String? ?? '',
        versionCode: json['versionCode'] is int
            ? json['versionCode'] as int
            : int.tryParse('${json['versionCode'] ?? ''}') ?? 0,
        url: json['url'] as String? ?? '',
        sha256: (json['sha256'] as String? ?? '').toLowerCase(),
        packageName: json['packageName'] as String? ?? '',
        signingCertificateSha256:
            (json['signingCertificateSha256'] as String? ?? '').toLowerCase(),
        signature: json['signature'] as String? ?? '',
        changelog: json['changelog'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'versionCode': versionCode,
        'url': url,
        'sha256': sha256,
        'packageName': packageName,
        'signingCertificateSha256': signingCertificateSha256,
        'changelog': changelog ?? '',
        'signature': signature,
      };

  void validate() {
    if (version.isEmpty || versionCode <= 0) {
      throw const FormatException('更新清单版本字段无效');
    }
    requireOfficialUpdateBaseUrl(url);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw const FormatException('更新清单缺少有效的 APK SHA-256');
    }
    if (packageName != solvhenPackageName) {
      throw const FormatException('更新清单包名不匹配');
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(signingCertificateSha256)) {
      throw const FormatException('更新清单缺少有效的签名证书 SHA-256');
    }
    try {
      if (base64Decode(signature).length != 64) {
        throw const FormatException('更新清单 Ed25519 签名长度无效');
      }
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('更新清单 Ed25519 签名格式无效');
    }
  }
}

String canonicalUpdateManifestPayload(UpdateInfo info) => jsonEncode({
      'version': info.version,
      'versionCode': info.versionCode,
      'url': info.url,
      'sha256': info.sha256,
      'packageName': info.packageName,
      'signingCertificateSha256': info.signingCertificateSha256,
      'changelog': info.changelog ?? '',
    });

Future<bool> verifyUpdateManifestSignature(
  UpdateInfo info, {
  String? publicKeyBase64,
}) async {
  info.validate();
  final encodedKey = publicKeyBase64 ?? officialUpdatePublicKeyBase64;
  late final List<int> publicKeyBytes;
  late final List<int> signatureBytes;
  try {
    publicKeyBytes = base64Decode(encodedKey);
    signatureBytes = base64Decode(info.signature);
  } catch (_) {
    throw const FormatException('OTA 发布公钥或清单签名不是有效 Base64');
  }
  if (publicKeyBytes.length != 32) {
    throw StateError('当前构建未内置有效的 OTA Ed25519 发布公钥');
  }
  final signature = Signature(
    signatureBytes,
    publicKey: SimplePublicKey(
      publicKeyBytes,
      type: KeyPairType.ed25519,
    ),
  );
  return Ed25519().verify(
    utf8.encode(canonicalUpdateManifestPayload(info)),
    signature: signature,
  );
}
