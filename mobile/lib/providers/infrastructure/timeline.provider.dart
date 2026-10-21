import 'package:collection/collection.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.state.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';

final timelineArgsProvider = Provider.autoDispose<TimelineArgs>(
  (ref) => throw UnimplementedError('Will be overridden through a ProviderScope.'),
);

/// JoshDrive: main timeline filter. 0 all, 1 only on this phone, 2 only on the server, 3 on both.
final timelineStorageFilterProvider = StateProvider<int>((ref) => 0);

final timelineServiceProvider = Provider<TimelineService>(
  (ref) {
    final timelineUsers = ref.watch(timelineUsersProvider).valueOrNull ?? [];
    final storage = ref.watch(timelineStorageFilterProvider);
    final timelineService = ref.watch(timelineFactoryProvider).main(timelineUsers, storage: storage);
    ref.onDispose(timelineService.dispose);
    return timelineService;
  },
  // Empty dependencies to inform the framework that this provider
  // might be used in a ProviderScope
  dependencies: const [],
);

final timelineFactoryProvider = Provider<TimelineFactory>(
  (ref) => TimelineFactory(
    timelineRepository: ref.watch(driftProvider).timelineRepository,
    settingsRepository: ref.watch(settingsProvider),
  ),
);

final timelineUsersProvider = StreamProvider<List<String>>((ref) {
  final currentUserId = ref.watch(currentUserProvider.select((u) => u?.id));
  if (currentUserId == null) {
    return Stream.value([]);
  }

  // Drift re-emits a fresh but content-identical list on unrelated table updates,
  // which would dispose and rebuild the timeline service mid-load
  return ref
      .watch(driftProvider)
      .timelineRepository
      .watchTimelineUserIds(currentUserId)
      .distinct(const ListEquality<String>().equals);
});
