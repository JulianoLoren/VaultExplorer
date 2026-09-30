import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vaultexplorer/core/api/vault_video_edit_api.dart';
import 'package:vaultexplorer/core/providers/vault_engine_providers.dart';

/// The video editor's native API. A plain (non-generated) provider on
/// purpose: it needs no `build_runner` step.
final vaultVideoEditApiProvider = Provider<VaultVideoEditApi>(
  (ref) => VaultVideoEditApi(ref.watch(vaultEngineChannelProvider)),
);
