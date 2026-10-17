import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/config/cleanup_config.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/repositories/permission.repository.dart';
import 'package:immich_mobile/services/cleanup.service.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:logging/logging.dart';

final autoFreeUpServiceProvider = Provider<AutoFreeUpService>(
  (ref) => AutoFreeUpService(ref.watch(cleanupServiceProvider), ref.watch(permissionRepositoryProvider)),
);

/// Automatic "Free Up Space" (Unrau fork): removes device copies older than the chosen age that are
/// confirmed on the server, using the same filters as the manual Free Up Space page (keep favorites,
/// kept albums, media type). Android only lets an app move media to the trash while it is on screen,
/// so the background worker only announces what is ready; opening the app (or tapping that notice)
/// does the move, without prompts once Media Management access is granted.
class AutoFreeUpService {
  static const _interval = Duration(hours: 20);
  static const _notificationId = 7301;
  static const _channel = AndroidNotificationDetails(
    'immich_auto_free_up',
    'Automatic free up space',
    channelDescription: 'Device copies of backed-up photos moved to the trash',
    importance: Importance.low,
  );

  final CleanupService _cleanupService;
  final DevicePermissionRepository _permissionRepository;
  final _log = Logger('AutoFreeUpService');
  static bool _running = false;

  AutoFreeUpService(this._cleanupService, this._permissionRepository);

  CleanupConfig get _config => SettingsRepository.instance.appConfig.cleanup;

  bool get _enabled => CurrentPlatform.isAndroid && _config.autoEnabled;

  bool get _due => DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(_config.autoLastRunMs)) >= _interval;

  Future<({List<String> ids, int bytes})> _candidates(String userId) async {
    final config = _config;
    final result = await _cleanupService.getRemovalCandidates(
      userId,
      DateTime.now().subtract(Duration(days: config.autoDaysAgo)),
      keepMediaType: config.keepMediaType,
      keepFavorites: config.keepFavorites,
      keepAlbumIds: config.keepAlbumIds.toSet(),
    );
    return (ids: result.assets.map((a) => a.id).toList(), bytes: result.totalBytes);
  }

  /// Called by the background worker after a backup run.
  Future<void> announceIfDue(String userId) async {
    if (!_enabled || !_due) {
      return;
    }
    try {
      final c = await _candidates(userId);
      if (c.ids.isEmpty) {
        return;
      }
      await _notify(
        '${formatBytes(c.bytes)} ready to free up',
        '${c.ids.length} backed-up items older than ${_config.autoDaysAgo} days. Tap to move them to the device trash.',
      );
    } catch (error, stack) {
      _log.warning('Auto free up check failed', error, stack);
    }
  }

  /// Called when the app comes to the foreground.
  Future<int> runIfDue(String userId) async {
    if (!_enabled || !_due) {
      return 0;
    }
    // Without Media Management access Android asks for every batch; the manual page handles that case.
    if (_running || !await _permissionRepository.hasManageMediaPermission()) {
      return 0;
    }
    _running = true;
    try {
      final c = await _candidates(userId);
      final deleted = c.ids.isEmpty ? 0 : await _cleanupService.deleteLocalAssets(c.ids);
      await SettingsRepository.instance.write(SettingsKey.cleanupAutoLastRunMs, DateTime.now().millisecondsSinceEpoch);
      await FlutterLocalNotificationsPlugin().cancel(_notificationId);
      if (deleted > 0) {
        _log.info('Auto free up moved $deleted items to the device trash');
        await _notify(
          'Freed ${formatBytes(c.bytes)}',
          '$deleted backed-up items older than ${_config.autoDaysAgo} days moved to the device trash. They stay on your server.',
        );
      }
      return deleted;
    } catch (error, stack) {
      _log.warning('Auto free up failed', error, stack);
      return 0;
    } finally {
      _running = false;
    }
  }

  Future<void> _notify(String title, String body) async {
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      const InitializationSettings(android: AndroidInitializationSettings('@drawable/notification_icon')),
    );
    await plugin.show(_notificationId, title, body, const NotificationDetails(android: _channel));
  }
}
