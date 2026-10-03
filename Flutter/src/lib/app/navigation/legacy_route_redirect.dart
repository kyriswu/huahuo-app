import '../../features/chat/domain/chat_models.dart';
import 'app_route_paths.dart';

/// Resolves historical `/main` deep links to maintained V3 destinations.
String? v3LocationForLegacyMainUri(Uri uri) {
  final path = uri.path;
  if (path == '/main' ||
      path == '/main/home' ||
      path == '/main/work-ai' ||
      path == '/main/creation' ||
      path == '/main/feed-ai') {
    return AppRoutePaths.home;
  }
  if (path == '/main/assets') return AppRoutePaths.assetsOverview;
  if (path == '/main/recording-card/connect') {
    return AppRoutePaths.recordingCardControl;
  }
  if (path == '/main/settings/diagnostics') {
    return AppRoutePaths.profileDiagnostics;
  }
  if (path == '/main/settings') return AppRoutePaths.profileSection('设置');
  if (path == '/main/quick-recording') return AppRoutePaths.recordSource;
  if (path == '/main/transcription-done') {
    return '/v3/feed/transcription-preview';
  }
  if (path == '/main/creation/selected') {
    final assetId = _safeCanvasTopicId(uri.queryParameters['feedItemId']);
    return assetId == null
        ? AppRoutePaths.canvas
        : AppRoutePaths.canvasForAsset(assetId);
  }
  if (path == '/main/creation/materials' ||
      path.startsWith('/main/creation/')) {
    return AppRoutePaths.canvas;
  }
  if (path == '/main/feed-ai/graph') return AppRoutePaths.graph;
  if (path == '/main/feed-ai/import') return AppRoutePaths.documentImport;
  if (path.startsWith('/main/placeholder/')) {
    final title = path.substring('/main/placeholder/'.length);
    return AppRoutePaths.profileSection(Uri.decodeComponent(title));
  }
  if (path.startsWith('/main/work-ai/thread/') ||
      path.startsWith('/main/feed-ai/thread/')) {
    final segments = uri.pathSegments;
    final threadId = segments.length == 4 ? segments.last : null;
    if (threadId == null || !isSafeChatIdentifier(threadId)) {
      return Uri(
        path: '/v3/feed/chat',
        queryParameters: const <String, String>{'threadId': ''},
      ).toString();
    }
    final purpose = path.startsWith('/main/work-ai/thread/')
        ? ChatConversationPurpose.deepPositioning
        : ChatConversationPurpose.general;
    return Uri(
      path: '/v3/feed/chat',
      queryParameters: <String, String>{
        'threadId': threadId,
        'purpose': purpose.routeValue,
      },
    ).toString();
  }
  return null;
}

String? _safeCanvasTopicId(String? value) {
  final normalized = value?.trim();
  if (normalized == null ||
      normalized.isEmpty ||
      normalized.length > 128 ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}
