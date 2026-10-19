import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// JoshDrive (Unrau fork) telemetry: sends this app's own log lines since the last send to Josh's
/// collector on the Immich host (tailnet only). The collector accepts a post only with a valid
/// login for that Immich server. Nothing else leaves the phone; failures are silent.
class Telemetry {
  static const _url = 'https://michelle-thinkcentre-m910q.tail0ffed4.ts.net:8461/telemetry';
  static const _minInterval = Duration(minutes: 15);
  static const _maxLines = 400;
  static bool _sending = false;
  static DateTime? _lastAttempt;

  static Future<void> send(String reason) async {
    final now = DateTime.now();
    if (_sending || (_lastAttempt != null && now.difference(_lastAttempt!) < _minInterval)) {
      return;
    }
    _sending = true;
    _lastAttempt = now;
    try {
      final token = Store.tryGet(StoreKey.accessToken);
      if (token == null || token.isEmpty) {
        return;
      }
      final marker = File('${(await getApplicationSupportDirectory()).path}/telemetry_last_sent');
      final since = marker.existsSync()
          ? DateTime.tryParse(marker.readAsStringSync()) ?? DateTime.fromMillisecondsSinceEpoch(0)
          : DateTime.fromMillisecondsSinceEpoch(0);
      await LogService.I.flush();
      final fresh = (await LogService.I.getMessages()).where((m) => m.createdAt.isAfter(since)).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final lines = fresh.length > _maxLines ? fresh.sublist(fresh.length - _maxLines) : fresh;
      final info = await PackageInfo.fromPlatform();
      String cut(String? s, int n) => s == null ? '' : (s.length > n ? s.substring(0, n) : s);
      final body = jsonEncode({
        'reason': reason,
        'app': '${info.version}+${info.buildNumber}',
        'os': Platform.operatingSystemVersion,
        'sentAt': now.toUtc().toIso8601String(),
        'dropped': fresh.length - lines.length,
        'logs': [
          for (final m in lines)
            {
              't': m.createdAt.toUtc().toIso8601String(),
              'level': m.level.name,
              'logger': m.logger,
              'msg': cut(m.message, 2000),
              if (m.error != null) 'error': cut(m.error, 2000),
              if (m.stack != null) 'stack': cut(m.stack, 4000),
            },
        ],
      });
      final response = await http
          .post(
            Uri.parse(_url),
            headers: {'Content-Type': 'application/json', 'x-immich-user-token': token},
            body: body,
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 200 && lines.isNotEmpty) {
        marker.writeAsStringSync(lines.last.createdAt.toIso8601String());
      }
    } catch (_) {
      // Offline or collector down: try again next time.
    } finally {
      _sending = false;
    }
  }
}
