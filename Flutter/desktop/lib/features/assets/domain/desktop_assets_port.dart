import '../../../shared/services/desktop_service_result.dart';

final class DesktopAssetSummary {
  const DesktopAssetSummary({
    required this.assetType,
    required this.assetId,
    required this.title,
  });

  final String assetType;
  final String assetId;
  final String title;
}

final class DesktopAssetOverview {
  const DesktopAssetOverview({
    required this.recordingCount,
    required this.transcriptWordCount,
    required this.contentLineCount,
    required this.lifeEventCount,
    required this.expressionCount,
    required this.syncStatus,
    this.items = const <DesktopAssetSummary>[],
    this.latestUpdatedAt,
  });

  final int recordingCount;
  final int transcriptWordCount;
  final int contentLineCount;
  final int lifeEventCount;
  final int expressionCount;
  final String syncStatus;
  final List<DesktopAssetSummary> items;
  final DateTime? latestUpdatedAt;
}

final class DesktopAssetDetail {
  const DesktopAssetDetail({
    required this.assetType,
    required this.assetId,
    required this.asset,
    required this.editable,
    required this.baseVersion,
    required this.updatedAt,
  });

  final String assetType;
  final String assetId;
  final Map<String, Object?> asset;
  final bool editable;
  final int baseVersion;
  final DateTime updatedAt;
}

final class DesktopAssetItem {
  const DesktopAssetItem({
    required this.id,
    required this.title,
    required this.markdown,
    required this.version,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String markdown;
  final int version;
  final DateTime updatedAt;
}

final class DesktopAssetSyncReceipt {
  const DesktopAssetSyncReceipt({required this.taskId, required this.status});

  final String taskId;
  final String status;
}

abstract interface class DesktopAssetsPort {
  Future<DesktopServiceResult<DesktopAssetOverview>> loadOverview();

  Future<DesktopServiceResult<DesktopAssetItem>> loadMarkdownDocument();

  Future<DesktopServiceResult<DesktopAssetDetail>> loadDetail({
    required String assetType,
    required String assetId,
  });

  Future<DesktopServiceResult<DesktopAssetSyncReceipt>> requestSync();
}
