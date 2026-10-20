import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/log.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// JoshDrive (Unrau fork) telemetry: sends this app's own log lines since the last send to Josh's
/// collector on the Immich host (tailnet only). The collector accepts a post only with a valid
/// login for that Immich server. Nothing else leaves the phone; failures are silent.
class Telemetry {
  static const _url = 'http://127.0.0.1:48283/telemetry'; // through the encrypted tunnel
  static Duration _minInterval = const Duration(minutes: 15);
  static int _maxLines = 400;
  static bool _sending = false;
  static DateTime? _lastAttempt;

  /// Registers this phone's tunnel key with the gateway (over Tailscale, proven by the Immich login),
  /// so drive.unraujoshua.com accepts it. Done once; harmless to repeat.
  static Future<void> _registerTunnelDevice(String token) async {
    try {
      final done = File('${(await getApplicationSupportDirectory()).path}/tunnel_registered');
      if (done.existsSync()) {
        return;
      }
      final pk = await const MethodChannel('joshdrive/tunnel').invokeMethod<String>('devicePk');
      if (pk == null) {
        return;
      }
      final response = await http
          .post(
            Uri.parse('https://michelle-thinkcentre-m910q.tail0ffed4.ts.net:8461/register-device'),
            headers: {'Content-Type': 'application/json', 'x-immich-user-token': token},
            body: jsonEncode({'devicePk': pk}),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        done.writeAsStringSync(pk);
      }
    } catch (_) {
      // Not on Tailscale right now; try again next time.
    }
  }

  static const tunnelUrl = 'http://127.0.0.1:48283';

  /// Moves this login onto the encrypted tunnel (drive.unraujoshua.com) as soon as the tunnel answers,
  /// which needs this phone to be registered with the gateway. The login token stays valid: same server.
  static Future<void> useTunnelIfReady(ApiService api) async {
    final current = Store.tryGet(StoreKey.serverEndpoint);
    if (current == null || current.startsWith(tunnelUrl)) {
      return;
    }
    try {
      final ping = await http.get(Uri.parse('$tunnelUrl/api/server/ping')).timeout(const Duration(seconds: 10));
      if (!ping.body.contains('pong')) {
        return;
      }
      await api.resolveAndSetEndpoint(tunnelUrl);
      await Store.put(StoreKey.serverUrl, tunnelUrl);
    } catch (_) {
      // Not registered yet or offline; the next resume tries again.
    }
  }

  /// Applies Josh's remote config (~/immich/gateway/config.json on the 910q). Returns true when it asks
  /// for an immediate log send (a new telemetry.sendNow value).
  static Future<bool> _applyRemoteConfig() async {
    try {
      final token = Store.tryGet(StoreKey.accessToken);
      if (token == null || token.isEmpty) {
        return false;
      }
      final response = await http
          .get(Uri.parse('$tunnelUrl/jd-config'), headers: {'x-immich-user-token': token})
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        return false;
      }
      final config = jsonDecode(response.body) as Map<String, dynamic>;
      final settings = SettingsRepository.instance;
      final telemetry = config['telemetry'];
      var forced = false;
      if (telemetry is Map) {
        if (telemetry['intervalMinutes'] is int) {
          _minInterval = Duration(minutes: telemetry['intervalMinutes'] as int);
        }
        if (telemetry['maxLines'] is int) {
          _maxLines = telemetry['maxLines'] as int;
        }
        final level = LogLevel.values.where((l) => l.name == telemetry['logLevel']).firstOrNull;
        if (level != null) {
          await LogService.I.setLogLevel(level);
        }
        final sendNow = telemetry['sendNow'];
        if (sendNow is String && sendNow.isNotEmpty) {
          final seen = File('${(await getApplicationSupportDirectory()).path}/telemetry_send_now');
          if (!seen.existsSync() || seen.readAsStringSync() != sendNow) {
            seen.writeAsStringSync(sendNow);
            forced = true;
          }
        }
      }
      final freeUp = config['autoFreeUp'];
      if (freeUp is Map) {
        if (freeUp['enabled'] is bool) {
          await settings.write(SettingsKey.cleanupAutoEnabled, freeUp['enabled'] as bool);
        }
        if (freeUp['days'] is int) {
          await settings.write(SettingsKey.cleanupAutoDaysAgo, freeUp['days'] as int);
        }
      }
      final backup = config['backup'];
      if (backup is Map && backup['enabled'] is bool) {
        await settings.write(SettingsKey.backupEnabled, backup['enabled'] as bool);
      }
      return forced;
    } catch (_) {
      return false;
    }
  }

  static Future<void> send(String reason) async {
    final now = DateTime.now();
    if (_sending) {
      return;
    }
    final forced = await _applyRemoteConfig();
    if (!forced && _lastAttempt != null && now.difference(_lastAttempt!) < _minInterval) {
      return;
    }
    _sending = true;
    _lastAttempt = now;
    try {
      final token = Store.tryGet(StoreKey.accessToken);
      if (token == null || token.isEmpty) {
        return;
      }
      await _registerTunnelDevice(token);
      final marker = File('${(await getApplicationSupportDirectory()).path}/telemetry_last_sent');
      final since = marker.existsSync()
          ? DateTime.tryParse(marker.readAsStringSync()) ?? DateTime.fromMillisecondsSinceEpoch(0)
          : DateTime.fromMillisecondsSinceEpoch(0);
      await LogService.I.flush();
      final fresh = (await LogService.I.getMessages()).where((m) => m.createdAt.isAfter(since)).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final lines = fresh.length > _maxLines ? fresh.sublist(fresh.length - _maxLines) : fresh;
      final info = await PackageInfo.fromPlatform();
      final tunnelEvents = await const MethodChannel(
        'joshdrive/tunnel',
      ).invokeListMethod<String>('tunnelEvents').catchError((_) => <String>[]);
      String cut(String? s, int n) => s == null ? '' : (s.length > n ? s.substring(0, n) : s);
      final body = jsonEncode({
        'reason': reason,
        'app': '${info.version}+${info.buildNumber}',
        'os': Platform.operatingSystemVersion,
        'sentAt': now.toUtc().toIso8601String(),
        'dropped': fresh.length - lines.length,
        'tunnel': tunnelEvents ?? <String>[],
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
