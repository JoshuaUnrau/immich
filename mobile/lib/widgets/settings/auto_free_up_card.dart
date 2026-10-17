import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/repositories/permission.repository.dart';

/// Settings for automatic Free Up Space (Unrau fork). Uses the "Keep on device" choices below.
class AutoFreeUpCard extends HookConsumerWidget {
  const AutoFreeUpCard({super.key});

  static const _ages = [30, 90, 180, 365];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cleanup = ref.watch(appConfigProvider).cleanup;
    final hasManageMedia = useState<bool?>(null);
    final lifecycle = useAppLifecycleState();

    Future<void> checkPermission() async {
      hasManageMedia.value = await ref.read(permissionRepositoryProvider).hasManageMediaPermission();
    }

    useEffect(() {
      unawaited(checkPermission());
      return null;
    }, [lifecycle]);

    final settings = ref.read(settingsProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Card(
        elevation: 0,
        color: context.colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          side: BorderSide(color: context.colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.auto_delete_outlined),
                title: Text(
                  'Free up space automatically',
                  style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'Once a day, move device copies already on your server to the trash',
                  style: context.textTheme.bodySmall,
                ),
                value: cleanup.autoEnabled,
                onChanged: (value) => unawaited(settings.write(.cleanupAutoEnabled, value)),
              ),
              if (cleanup.autoEnabled) ...[
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Row(
                    children: [
                      Expanded(child: Text('Only items older than', style: context.textTheme.bodyMedium)),
                      DropdownButton<int>(
                        value: _ages.contains(cleanup.autoDaysAgo) ? cleanup.autoDaysAgo : 90,
                        items: [for (final d in _ages) DropdownMenuItem(value: d, child: Text('$d days'))],
                        onChanged: (value) {
                          if (value != null) {
                            unawaited(settings.write(.cleanupAutoDaysAgo, value));
                          }
                        },
                      ),
                    ],
                  ),
                ),
                Text(
                  'Uses your "Keep on device" choices. Trashed items stay in the device trash for 30 days.',
                  style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
                ),
                if (hasManageMedia.value == false) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Needs Media management access so Android lets Immich move photos to the trash without asking each time.',
                    style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.error),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.lock_open),
                    label: const Text('Allow media management'),
                    onPressed: () async {
                      await ref.read(permissionRepositoryProvider).requestManageMediaPermission();
                      await checkPermission();
                    },
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
