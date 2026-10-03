abstract final class AppRoutePaths {
  static const splash = '/splash';
  static const restoreFailed = '/restore-failed';
  static const auth = '/auth';
  static const home = '/v3';
  static const feedMode = 'feed';
  static const workbenchMode = 'workbench';
  static const masterpieceMode = 'masterpiece';
  static const notifications = '/v3/notifications';
  static const search = '/v3/search';
  static const assets = '/v3/assets';
  static const assetsMedia = '$assets?label=media';
  static const photoAlbumPreviewRoute = '$assets/media/:resourceId';
  static const linkImport = '/v3/feed/link-import';
  static const documentImport = '/v3/feed/import/documents';
  static const mediaImport = '/v3/feed/import/media';
  static const recordSource = '/v3/feed/record-source';
  static const meetingCapture = '/v3/feed/meeting';
  static const internalRecording = '/v3/feed/internal-recording';
  static const transcriptionDoneRoute =
      '/v3/feed/transcription-done/:recordingId';
  static const transcriptionJobRoute = '/v3/feed/transcription-jobs/:jobId';
  static const graph = '/v3/feed/graph';
  static const canvas = '/v3/workbench/canvas';
  static const _workbenchMaterialsBase = '/v3/workbench/materials';
  static const _workbenchGeneratingBase = '/v3/workbench/generating';
  static const _workbenchGeneratedBase = '/v3/workbench/generated';
  static const workbenchMaterialsRoute = '$_workbenchMaterialsBase/:purpose';
  static const workbenchGeneratingRoute = '$_workbenchGeneratingBase/:purpose';
  static const workbenchGeneratedRoute = '$_workbenchGeneratedBase/:purpose';
  static const recordingCardControl = '/v3/recording-card/control';
  static const recordingCardFiles = '/v3/recording-card/files';
  static const transcriptionBatchRoute =
      '/v3/feed/transcription-batches/:batchId';
  static const firstLaunchDeviceSetup = '/v3/onboarding/device-setup';
  static const legacyPostPositioningSetup = '/v3/onboarding/setup';
  static const assetsOverview = '$assets?focus=overview';
  static const knowledge = '/v3/profile/knowledge';
  static const digitalTwin = '/v3/profile/digital-twin';
  static const positioningReport = '/v3/workbench/deep-positioning';
  static const knowledgeSquare = '$knowledge?tab=square';
  static const knowledgeChannelRoute = '$knowledge/channel/:channelId';
  static const knowledgeWorld = '$knowledge/world';

  static String homeForMode(String? mode) {
    final normalized = switch (mode?.trim().toLowerCase()) {
      workbenchMode => workbenchMode,
      masterpieceMode => masterpieceMode,
      _ => feedMode,
    };
    return normalized == feedMode ? home : '$home?mode=$normalized';
  }

  static String get workbench => homeForMode(workbenchMode);

  static String photoAlbumPreview(String resourceId) =>
      '$assets/media/${Uri.encodeComponent(resourceId)}';

  static String get freshLinkImport =>
      _withQuery(linkImport, const <String, String>{'entry': 'fresh'});

  static String linkImportForDraft(String draftId) =>
      _withQuery(linkImport, <String, String>{'draftId': draftId});

  static String get freshDocumentImport =>
      _withQuery(documentImport, const <String, String>{'entry': 'fresh'});

  static String documentImportForTask(String taskId) =>
      _withQuery(documentImport, <String, String>{'taskId': taskId});

  static String get freshMediaImport =>
      _withQuery(mediaImport, const <String, String>{'entry': 'fresh'});

  static String get freshRecordSource =>
      _withQuery(recordSource, const <String, String>{'entry': 'fresh'});

  static String recordingCapture({
    required bool external,
    bool freshEntry = false,
    bool distillToDigitalTwin = false,
    String? draftId,
  }) => _withQuery(
    external ? meetingCapture : internalRecording,
    <String, String>{
      if (freshEntry) 'entry': 'fresh',
      if (distillToDigitalTwin) 'distillToDigitalTwin': '1',
      if (draftId != null && draftId.isNotEmpty) 'draftId': draftId,
    },
  );

  static String transcriptionDetail(
    String recordingId, {
    String? source,
    String? destination,
  }) => _withQuery(
    '/v3/feed/transcription-done/${Uri.encodeComponent(recordingId)}',
    <String, String>{
      if (source != null && source.isNotEmpty) 'source': source,
      if (destination == 'raw' || destination == 'summary')
        'destination': destination!,
    },
  );

  static String transcriptionJob(
    String jobId, {
    String? source,
    String? destination,
  }) => _withQuery(
    '/v3/feed/transcription-jobs/${Uri.encodeComponent(jobId)}',
    <String, String>{
      if (source != null && source.isNotEmpty) 'source': source,
      if (destination == 'raw' || destination == 'summary')
        'destination': destination!,
    },
  );

  static String transcriptionBatch(String batchId, {String? focusItem}) =>
      _withQuery(
        '/v3/feed/transcription-batches/${Uri.encodeComponent(batchId)}',
        <String, String>{
          if (focusItem != null && focusItem.trim().isNotEmpty)
            'focusItem': focusItem.trim(),
        },
      );

  static String workbenchMaterials(String purpose) =>
      '$_workbenchMaterialsBase/${Uri.encodeComponent(purpose)}';

  static String workbenchGenerating(String purpose) =>
      '$_workbenchGeneratingBase/${Uri.encodeComponent(purpose)}';

  static String workbenchGenerated(String purpose) =>
      '$_workbenchGeneratedBase/${Uri.encodeComponent(purpose)}';

  static String feedItem(String itemId, {String? stage}) {
    final encodedId = Uri.encodeComponent(itemId);
    final normalizedStage = stage?.trim();
    return normalizedStage == null || normalizedStage.isEmpty
        ? '/v3/feed/items/$encodedId'
        : '/v3/feed/items/$encodedId?stage=${Uri.encodeQueryComponent(normalizedStage)}';
  }

  static String feedItemAppend(String itemId, String source) =>
      '/v3/feed/items/${Uri.encodeComponent(itemId)}/append/'
      '${Uri.encodeComponent(source)}';

  static String editNote(String itemId) =>
      '/v3/feed/note/${Uri.encodeComponent(itemId)}';

  static String canvasForAsset(String assetId) =>
      '$canvas?importAssetId=${Uri.encodeQueryComponent(assetId)}';

  static String profileSection(String section) =>
      '/v3/profile/${Uri.encodeComponent(section)}';

  static String get profileDiagnostics => profileSection('诊断');

  static String knowledgeChannel(String channelId) =>
      '$knowledge/channel/${Uri.encodeComponent(channelId)}';

  static String positioningReportForTask(String taskId) => _withQuery(
    positioningReport,
    <String, String>{'focus': 'report', 'taskId': taskId},
  );

  static String knowledgeWorldDetail({String? publicationId, String? query}) {
    final queryParameters = <String, String>{};
    final normalizedPublicationId = publicationId?.trim();
    if (normalizedPublicationId != null && normalizedPublicationId.isNotEmpty) {
      queryParameters['publicationId'] = normalizedPublicationId;
    }
    final normalizedQuery = query?.trim();
    if (normalizedQuery != null && normalizedQuery.isNotEmpty) {
      queryParameters['q'] = normalizedQuery;
    }
    return Uri(
      path: knowledgeWorld,
      queryParameters: queryParameters.isEmpty ? null : queryParameters,
    ).toString();
  }

  static bool isV3Location(String location) {
    final uri = Uri.tryParse(location);
    if (uri == null ||
        uri.hasScheme ||
        uri.hasAuthority ||
        uri.fragment.isNotEmpty) {
      return false;
    }
    return uri.path == home || uri.path.startsWith('$home/');
  }

  static String _withQuery(String path, Map<String, String> queryParameters) =>
      Uri.parse(path)
          .replace(
            queryParameters: queryParameters.isEmpty ? null : queryParameters,
          )
          .toString();
}
