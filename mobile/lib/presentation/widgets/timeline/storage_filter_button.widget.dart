import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';

/// JoshDrive: filter the main timeline by where each item is stored.
class StorageFilterButton extends ConsumerWidget {
  const StorageFilterButton({super.key});

  static const _options = [
    (0, Icons.photo_library_outlined, 'All photos'),
    (1, Icons.cloud_off_outlined, 'Only on this phone'),
    (2, Icons.cloud_outlined, 'Only on server'),
    (3, Icons.cloud_done_outlined, 'On phone and server'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(timelineStorageFilterProvider);
    final active = current != 0;
    return PopupMenuButton<int>(
      tooltip: 'Filter by storage',
      initialValue: current,
      onSelected: (value) => ref.read(timelineStorageFilterProvider.notifier).state = value,
      icon: Icon(
        active ? _options[current].$2 : Icons.filter_list_rounded,
        color: active ? context.primaryColor : null,
      ),
      itemBuilder: (_) => [
        for (final (value, icon, label) in _options)
          PopupMenuItem(
            value: value,
            child: Row(
              children: [
                Icon(icon, size: 20, color: value == current ? context.primaryColor : null),
                const SizedBox(width: 12),
                Text(label),
              ],
            ),
          ),
      ],
    );
  }
}
