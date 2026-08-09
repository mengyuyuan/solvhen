import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:solvhen/core/security/update_manifest.dart';

Future<void> main(List<String> arguments) async {
  final args = _parseArguments(arguments);
  final apkPath = _required(args, 'apk');
  final version = _required(args, 'version');
  final versionCode = int.parse(_required(args, 'version-code'));
  final apkUrl = _required(args, 'url');
  final certificate = _required(args, 'certificate-sha256').toLowerCase();
  final outputPath = _required(args, 'output');
  final privateKeyBase64 = args['private-key-base64'] ??
      Platform.environment['SOLVHEN_OTA_PRIVATE_KEY'] ??
      '';
  final privateSeed = base64Decode(privateKeyBase64);
  if (privateSeed.length != 32) {
    throw const FormatException(
      'SOLVHEN_OTA_PRIVATE_KEY must be a Base64 encoded 32-byte Ed25519 seed',
    );
  }

  final apk = File(apkPath);
  if (!await apk.exists()) throw ArgumentError('APK not found: $apkPath');
  final apkSha256 = sha256.convert(await apk.readAsBytes()).toString();
  final placeholder = base64Encode(List<int>.filled(64, 0));
  final unsigned = UpdateInfo(
    version: version,
    versionCode: versionCode,
    url: apkUrl,
    sha256: apkSha256,
    packageName: solvhenPackageName,
    signingCertificateSha256: certificate,
    signature: placeholder,
    changelog: args['changelog'] ?? '',
  );
  unsigned.validate();

  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(privateSeed);
  final signature = await algorithm.sign(
    utf8.encode(canonicalUpdateManifestPayload(unsigned)),
    keyPair: keyPair,
  );
  final manifest = UpdateInfo(
    version: unsigned.version,
    versionCode: unsigned.versionCode,
    url: unsigned.url,
    sha256: unsigned.sha256,
    packageName: unsigned.packageName,
    signingCertificateSha256: unsigned.signingCertificateSha256,
    signature: base64Encode(signature.bytes),
    changelog: unsigned.changelog,
  );
  final publicKey = await keyPair.extractPublicKey();
  final publicKeyBase64 = base64Encode(publicKey.bytes);
  final expectedPublicKey =
      Platform.environment['SOLVHEN_OTA_PUBLIC_KEY']?.trim() ?? '';
  if (expectedPublicKey.isNotEmpty && expectedPublicKey != publicKeyBase64) {
    throw StateError(
      'SOLVHEN_OTA_PUBLIC_KEY does not match SOLVHEN_OTA_PRIVATE_KEY',
    );
  }
  if (!await verifyUpdateManifestSignature(
    manifest,
    publicKeyBase64: publicKeyBase64,
  )) {
    throw StateError('Generated manifest failed self-verification');
  }

  final output = File(outputPath);
  await output.parent.create(recursive: true);
  await output.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(manifest.toJson())}\n',
    flush: true,
  );
  stdout.writeln('Manifest: ${output.path}');
  stdout.writeln('APK SHA-256: $apkSha256');
  stdout.writeln('OTA public key: $publicKeyBase64');
}

Map<String, String> _parseArguments(List<String> arguments) {
  final result = <String, String>{};
  for (final argument in arguments) {
    if (!argument.startsWith('--') || !argument.contains('=')) {
      throw FormatException('Expected --name=value, got: $argument');
    }
    final separator = argument.indexOf('=');
    result[argument.substring(2, separator)] =
        argument.substring(separator + 1);
  }
  return result;
}

String _required(Map<String, String> args, String name) {
  final value = args[name]?.trim() ?? '';
  if (value.isEmpty) throw ArgumentError('Missing --$name=value');
  return value;
}
