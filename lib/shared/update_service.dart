import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

const _owner = 'apazosg';
const _repo = 'markly';

class UpdateInfo {
  final String version;
  final String msixUrl;
  final String apkUrl;

  const UpdateInfo({
    required this.version,
    required this.msixUrl,
    required this.apkUrl,
  });
}

class UpdateService {
  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final current = info.version;

      final response = await http
          .get(
            Uri.parse(
                'https://api.github.com/repos/$_owner/$_repo/releases/latest'),
            headers: {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final tag = (data['tag_name'] as String?)?.replaceFirst('v', '') ?? '';

      if (!_isNewer(tag, current)) return null;

      final fullTag = 'v$tag';
      final base =
          'https://github.com/$_owner/$_repo/releases/download/$fullTag';

      return UpdateInfo(
        version: tag,
        msixUrl: '$base/markly-windows-$fullTag.msix',
        apkUrl: '$base/markly-android-$fullTag.apk',
      );
    } catch (_) {
      return null;
    }
  }

  // Returns the appropriate install URL for the current platform.
  // Windows uses ms-appinstaller:// so App Installer handles the MSIX directly.
  static String installUrl(UpdateInfo info) {
    if (Platform.isWindows) {
      return 'ms-appinstaller://?source=${Uri.encodeComponent(info.msixUrl)}';
    }
    return info.apkUrl;
  }

  static bool _isNewer(String remote, String local) {
    try {
      final r = _parse(remote);
      final l = _parse(local);
      for (var i = 0; i < 3; i++) {
        if (r[i] > l[i]) { return true; }
        if (r[i] < l[i]) { return false; }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  static List<int> _parse(String v) {
    final parts = v.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    while (parts.length < 3) { parts.add(0); }
    return parts;
  }
}
