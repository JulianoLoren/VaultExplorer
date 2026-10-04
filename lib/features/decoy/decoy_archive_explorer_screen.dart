import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vaultexplorer/core/api/vault_engine_types.dart';
import 'package:vaultexplorer/core/providers/vault_engine_providers.dart';
import 'package:vaultexplorer/data/services/secure_screen_policy.dart';
import 'package:vaultexplorer/features/decoy/local/decoy_file_manager_screen.dart';
import 'package:vaultexplorer/features/external_file_open/external_file_open_flow.dart';

/// The decoy disguise surface -- shown when the app opens in Mask Mode.
/// Hosts [DecoyFileManagerScreen] directly: the same file-manager UI used
/// to browse an unlocked vault (toolbar, settings, bookmarks, thumbnails,
/// text/image editor), pointed at real device storage. Replaces the old,
/// separately-built DecoyLocalExplorerScreen.
class DecoyArchiveExplorerScreen extends ConsumerStatefulWidget {
  const DecoyArchiveExplorerScreen({super.key});

  @override
  ConsumerState<DecoyArchiveExplorerScreen> createState() =>
      _DecoyArchiveExplorerScreenState();
}

class _DecoyArchiveExplorerScreenState
    extends ConsumerState<DecoyArchiveExplorerScreen> {
  late final _engineEvents = ref.read(vaultEngineEventsProvider);
  final Set<String> _handledExternalOpenRequestIds = {};

  @override
  void initState() {
    super.initState();
    // Disable screenshot blocking while in decoy mode
    unawaited(ref.read(secureScreenPolicyProvider).disableForDecoy());
    _engineEvents.addExternalFileOpenRequestListener(
      _onExternalFileOpenRequest,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPendingExternalFileOpen();
    });
  }

  Future<void> _checkPendingExternalFileOpen() async {
    final request = await ref
        .read(vaultLifecycleApiProvider)
        .checkPendingExternalFileOpen();
    if (request != null && mounted) _onExternalFileOpenRequest(request);
  }

  void _onExternalFileOpenRequest(ExternalFileOpenRequest request) {
    if (!mounted || !_handledExternalOpenRequestIds.add(request.id)) return;
    unawaited(presentExternalFileOpen(context, ref, request));
  }

  @override
  void dispose() {
    _engineEvents.removeExternalFileOpenRequestListener(
      _onExternalFileOpenRequest,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const DecoyFileManagerScreen();
  }
}
