import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/native/incoming_material_port.dart';
import '../../core/native/knowledge_export_port.dart';
import '../../core/native/native_file_port.dart';
import '../../core/native/platform_permissions_port.dart';
import '../../core/native/screen_capture_port.dart';

// Platform adapters belong to the composition layer. Feature code consumes
// typed ports without importing the global app provider module.

// resident-provider: Shares one platform export adapter identity across export and share consumers.
final knowledgeExportPlatformPortProvider =
    Provider<MethodChannelKnowledgeExportPort>((ref) {
      return const MethodChannelKnowledgeExportPort();
    });

// resident-provider: Preserves the shared export adapter identity for share consumers.
final knowledgeSharePortProvider = Provider<KnowledgeSharePort>((ref) {
  return ref.watch(knowledgeExportPlatformPortProvider);
});

// resident-provider: Preserves the shared export adapter identity for prepared-document consumers.
final nativePreparedDocumentExportPortProvider =
    Provider<NativePreparedDocumentExportPort>((ref) {
      return ref.watch(knowledgeExportPlatformPortProvider);
    });

// resident-provider: Preserves the shared export adapter identity for prepared-share consumers.
final nativePreparedDocumentSharePortProvider =
    Provider<NativePreparedDocumentSharePort>((ref) {
      return ref.watch(knowledgeExportPlatformPortProvider);
    });

// resident-provider: Shares one file picker adapter identity across app consumers.
final nativeFilePortProvider = Provider<NativeFilePort>((ref) {
  return const MethodChannelNativeFilePort();
});

// resident-provider: Keeps the incoming-material event adapter stable across route consumers.
final incomingMaterialPortProvider = Provider<IncomingMaterialPort>((ref) {
  return MethodChannelIncomingMaterialPort();
});

// resident-provider: Keeps the capture adapter and its state stable across route consumers.
final screenCapturePortProvider = Provider<ScreenCapturePort>((ref) {
  return MethodChannelScreenCapturePort();
});

// resident-provider: Shares one permissions adapter identity across app consumers.
final platformPermissionsPortProvider = Provider<PlatformPermissionsPort>((
  ref,
) {
  return const MethodChannelPlatformPermissionsPort();
});
