import 'dart:convert';
import 'dart:math';

import '../storage/secret_store.dart';

/// Process-local gate for capabilities that can rebuild or replace the app.
///
/// The persisted choice is hydrated at startup, but this object intentionally
/// contains no secret. The rebuild token always stays in Android Keystore via
/// [SecretStore].
class DeveloperModeSession {
  DeveloperModeSession._();

  static final DeveloperModeSession instance = DeveloperModeSession._();

  bool _enabled = false;
  bool get enabled => _enabled;

  void hydrate(bool enabled) => _enabled = enabled;
  void setEnabled(bool enabled) => _enabled = enabled;
}

class DeveloperCredentials {
  DeveloperCredentials({SecretStore? secrets})
      : _secrets = secrets ?? PlatformSecretStore.instance;

  final SecretStore _secrets;

  Future<String?> readToken() => _secrets.read(SecretKeys.devServerToken);

  Future<String> loadOrCreateToken() async {
    final existing = await readToken();
    if (existing != null && existing.length >= 32) return existing;
    return rotateToken();
  }

  Future<String> rotateToken() async {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final token = base64UrlEncode(bytes).replaceAll('=', '');
    await _secrets.write(SecretKeys.devServerToken, token);
    return token;
  }
}

/// Rebuild traffic is local-network development traffic only. Public hosts,
/// embedded credentials, query strings and non-HTTP schemes are rejected.
Uri? normalizePrivateDeveloperUrl(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.hasAuthority ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.userInfo.isNotEmpty ||
      uri.query.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      uri.host.isEmpty ||
      !_isPrivateOrLoopbackHost(uri.host)) {
    return null;
  }
  final normalizedPath = uri.path.replaceAll(RegExp(r'/+$'), '');
  return uri.replace(path: normalizedPath, query: null, fragment: null);
}

bool _isPrivateOrLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  if (normalized == 'localhost') return true;

  final address = InternetAddressParser.tryParse(normalized);
  if (address == null) return false;
  if (address.length == 4) {
    final a = address[0];
    final b = address[1];
    return a == 127 ||
        a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 169 && b == 254);
  }
  // ::1, fc00::/7 (ULA), fe80::/10 (link-local).
  return (address.take(15).every((byte) => byte == 0) && address.last == 1) ||
      (address.first & 0xfe) == 0xfc ||
      (address.first == 0xfe && (address[1] & 0xc0) == 0x80);
}

/// Tiny dependency-free IP parser used by both production code and tests.
abstract final class InternetAddressParser {
  static List<int>? tryParse(String host) {
    final ipv4 = host.split('.');
    if (ipv4.length == 4) {
      final bytes = <int>[];
      for (final part in ipv4) {
        if (part.isEmpty || (part.length > 1 && part.startsWith('0'))) {
          return null;
        }
        final value = int.tryParse(part);
        if (value == null || value < 0 || value > 255) return null;
        bytes.add(value);
      }
      return bytes;
    }

    // Uri.parse canonicalizes bracketed IPv6 hosts without brackets. Expand
    // the one optional :: gap into eight 16-bit groups.
    if (!host.contains(':')) return null;
    if (host.contains('.')) return null; // IPv4-mapped form is not needed here.
    final halves = host.split('::');
    if (halves.length > 2) return null;
    final left = halves.first.isEmpty ? <String>[] : halves.first.split(':');
    final right = halves.length == 1 || halves.last.isEmpty
        ? <String>[]
        : halves.last.split(':');
    final missing = 8 - left.length - right.length;
    if ((halves.length == 1 && missing != 0) ||
        (halves.length == 2 && missing < 1)) {
      return null;
    }
    final groups = <String>[
      ...left,
      ...List.filled(missing, '0'),
      ...right,
    ];
    if (groups.length != 8) return null;
    final bytes = <int>[];
    for (final group in groups) {
      if (group.isEmpty || group.length > 4) return null;
      final value = int.tryParse(group, radix: 16);
      if (value == null || value < 0 || value > 0xffff) return null;
      bytes
        ..add(value >> 8)
        ..add(value & 0xff);
    }
    return bytes;
  }
}
