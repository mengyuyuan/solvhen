import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solvhen/services/update_service.dart';

void main() {
  final validSha256 = List.filled(64, 'a').join();
  final validCertificate = List.filled(64, 'b').join();
  final placeholderSignature = base64Encode(List.filled(64, 0));

  group('official update endpoint', () {
    test('accepts only the fixed official HTTPS host', () {
      expect(
        normalizeOfficialUpdateBaseUrl('https://ota.sywy.app/'),
        officialUpdateBaseUrl,
      );
      expect(
        normalizeOfficialUpdateBaseUrl('https://ota.sywy.app/releases'),
        '$officialUpdateBaseUrl/releases',
      );
      expect(normalizeOfficialUpdateBaseUrl('http://ota.sywy.app'), isNull);
      expect(normalizeOfficialUpdateBaseUrl('https://ota.sywy.app.evil.test'),
          isNull);
      expect(
          normalizeOfficialUpdateBaseUrl('https://example.trycloudflare.com'),
          isNull);
      expect(normalizeOfficialUpdateBaseUrl(''), isNull);
    });

    test('requires package identity and APK SHA-256 in manifest', () {
      final valid = UpdateInfo(
        version: '3.0.0',
        versionCode: 30,
        url: '$officialUpdateBaseUrl/releases/solvhen.apk',
        sha256: validSha256,
        packageName: solvhenPackageName,
        signingCertificateSha256: validCertificate,
        signature: placeholderSignature,
      );
      expect(valid.validate, returnsNormally);

      expect(
        () => UpdateInfo(
          version: '3.0.0',
          versionCode: 30,
          url: '$officialUpdateBaseUrl/releases/solvhen.apk',
          sha256: validSha256,
          packageName: 'example.tampered',
          signingCertificateSha256: validCertificate,
          signature: placeholderSignature,
        ).validate(),
        throwsFormatException,
      );
      expect(
        () => UpdateInfo(
          version: '3.0.0',
          versionCode: 30,
          url: 'https://attacker.example/solvhen.apk',
          sha256: validSha256,
          packageName: solvhenPackageName,
          signingCertificateSha256: validCertificate,
          signature: placeholderSignature,
        ).validate(),
        throwsFormatException,
      );
      expect(
        () => const UpdateInfo(
          version: '3.0.0',
          versionCode: 30,
          url: '$officialUpdateBaseUrl/releases/solvhen.apk',
          sha256: 'not-a-sha256',
          packageName: solvhenPackageName,
          signingCertificateSha256:
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          signature:
              'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==',
        ).validate(),
        throwsFormatException,
      );
    });

    test('rejects a manifest changed after Ed25519 signing', () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final unsigned = UpdateInfo(
        version: '3.0.0',
        versionCode: 30,
        url: '$officialUpdateBaseUrl/releases/solvhen.apk',
        sha256: validSha256,
        packageName: solvhenPackageName,
        signingCertificateSha256: validCertificate,
        signature: placeholderSignature,
        changelog: '安全更新',
      );
      final signedBytes = await algorithm.sign(
        utf8.encode(canonicalUpdateManifestPayload(unsigned)),
        keyPair: keyPair,
      );
      final signed = UpdateInfo(
        version: unsigned.version,
        versionCode: unsigned.versionCode,
        url: unsigned.url,
        sha256: unsigned.sha256,
        packageName: unsigned.packageName,
        signingCertificateSha256: unsigned.signingCertificateSha256,
        signature: base64Encode(signedBytes.bytes),
        changelog: unsigned.changelog,
      );
      final encodedPublicKey = base64Encode(publicKey.bytes);

      expect(
        await verifyUpdateManifestSignature(
          signed,
          publicKeyBase64: encodedPublicKey,
        ),
        isTrue,
      );

      final tampered = UpdateInfo(
        version: signed.version,
        versionCode: signed.versionCode + 1,
        url: signed.url,
        sha256: signed.sha256,
        packageName: signed.packageName,
        signingCertificateSha256: signed.signingCertificateSha256,
        signature: signed.signature,
        changelog: signed.changelog,
      );
      expect(
        await verifyUpdateManifestSignature(
          tampered,
          publicKeyBase64: encodedPublicKey,
        ),
        isFalse,
      );
    });
  });
}
