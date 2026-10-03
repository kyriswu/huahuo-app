import 'package:huahuo_api/huahuo_api.dart';

import '../../../shared/services/desktop_service_result.dart';
import '../domain/desktop_assets_port.dart';

final class RemoteDesktopAssetsPort implements DesktopAssetsPort {
  const RemoteDesktopAssetsPort(this._apiClient);

  final ApiClient _apiClient;

  @override
  Future<DesktopServiceResult<DesktopAssetOverview>> loadOverview() async {
    final result = await _apiClient.request<DesktopAssetOverview>(
      ApiRequestOptions<DesktopAssetOverview>(
        endpointId: 'assetsOverview',
        parseData: (value) {
          final root = asObjectMap(value);
          final overview = asObjectMap(root?['overview']);
          if (overview == null) return null;
          final recordingCount = overview['recordingCount'];
          final transcriptWordCount = overview['transcriptWordCount'];
          final contentLineCount = overview['contentLineCount'];
          final lifeEventCount = overview['lifeEventCount'];
          final expressionCount = overview['expressionCount'];
          final syncStatus = overview['syncStatus'];
          final rawUpdatedAt = overview['latestUpdatedAt'];
          final updatedAt = rawUpdatedAt == null
              ? null
              : DateTime.tryParse(rawUpdatedAt.toString())?.toUtc();
          if (recordingCount is! int ||
              transcriptWordCount is! int ||
              contentLineCount is! int ||
              lifeEventCount is! int ||
              expressionCount is! int ||
              syncStatus is! String ||
              (rawUpdatedAt != null && updatedAt == null)) {
            return null;
          }
          final rawContentLines = root?['contentLines'];
          if (rawContentLines != null && rawContentLines is! List) return null;
          final items = <DesktopAssetSummary>[];
          for (final raw in rawContentLines as List? ?? const <Object?>[]) {
            final line = asObjectMap(raw);
            final id = line?['contentLineId'];
            final title = line?['name'] ?? line?['title'];
            if (id is! String || title is! String) return null;
            items.add(
              DesktopAssetSummary(
                assetType: 'content_line',
                assetId: id,
                title: title,
              ),
            );
          }
          return DesktopAssetOverview(
            recordingCount: recordingCount,
            transcriptWordCount: transcriptWordCount,
            contentLineCount: contentLineCount,
            lifeEventCount: lifeEventCount,
            expressionCount: expressionCount,
            syncStatus: syncStatus,
            items: items,
            latestUpdatedAt: updatedAt,
          );
        },
      ),
    );
    return result.ok
        ? DesktopServiceResult<DesktopAssetOverview>.success(result.data!)
        : _failure(result);
  }

  @override
  Future<DesktopServiceResult<DesktopAssetItem>> loadMarkdownDocument() async {
    final result = await _apiClient.request<SharedAssetMarkdownDocument>(
      ApiRequestOptions<SharedAssetMarkdownDocument>(
        endpointId: 'assetsMarkdown',
        parseData: (value) {
          final root = asObjectMap(value);
          final document = asObjectMap(root?['document']);
          return document == null
              ? null
              : SharedAssetMarkdownDocument.fromJson(document);
        },
      ),
    );
    if (!result.ok) return _failure(result);
    final document = result.data!;
    return DesktopServiceResult<DesktopAssetItem>.success(
      DesktopAssetItem(
        id: document.documentId,
        title: document.title,
        markdown: document.markdown,
        version: document.documentVersion,
        updatedAt: document.sourceUpdatedAt ?? document.renderedAt,
      ),
    );
  }

  @override
  Future<DesktopServiceResult<DesktopAssetDetail>> loadDetail({
    required String assetType,
    required String assetId,
  }) async {
    const allowedTypes = <String>{
      'content_line',
      'profile_overview',
      'life_event',
      'viewpoint',
      'expression',
      'synonym',
    };
    if (!allowedTypes.contains(assetType) || assetId.trim().isEmpty) {
      return const DesktopServiceResult<DesktopAssetDetail>.failure(
        code: 'DESKTOP_ASSET_ID_INVALID',
        message: '资产标识无效',
      );
    }
    final result = await _apiClient.request<DesktopAssetDetail>(
      ApiRequestOptions<DesktopAssetDetail>(
        endpointId: 'assetDetail',
        pathParams: <String, Object>{
          'assetType': assetType,
          'assetId': assetId,
        },
        parseData: (value) {
          final json = asObjectMap(value);
          final type = json?['assetType'];
          final id = json?['assetId'];
          final asset = asObjectMap(json?['asset']);
          final editable = json?['editable'];
          final baseVersion = json?['baseVersion'];
          final updatedAt = DateTime.tryParse(
            '${json?['updatedAt'] ?? ''}',
          )?.toUtc();
          if (type is! String ||
              id is! String ||
              asset == null ||
              editable is! bool ||
              baseVersion is! int ||
              updatedAt == null) {
            return null;
          }
          return DesktopAssetDetail(
            assetType: type,
            assetId: id,
            asset: asset,
            editable: editable,
            baseVersion: baseVersion,
            updatedAt: updatedAt,
          );
        },
      ),
    );
    return result.ok
        ? DesktopServiceResult<DesktopAssetDetail>.success(result.data!)
        : _failure(result);
  }

  @override
  Future<DesktopServiceResult<DesktopAssetSyncReceipt>> requestSync() async {
    final result = await _apiClient.request<DesktopAssetSyncReceipt>(
      ApiRequestOptions<DesktopAssetSyncReceipt>(
        endpointId: 'syncAssets',
        body: const <String, Object?>{},
        idempotency: const IdempotencyRequestContext(
          operation: 'desktop.assets.sync',
        ),
        parseData: (value) {
          final json = asObjectMap(value);
          final taskId = json?['taskId'];
          final status = json?['status'];
          if (taskId is! String || status is! String) return null;
          if (status != 'queued' && status != 'running') return null;
          return DesktopAssetSyncReceipt(taskId: taskId, status: status);
        },
      ),
    );
    return result.ok
        ? DesktopServiceResult<DesktopAssetSyncReceipt>.success(result.data!)
        : _failure(result);
  }
}

final class UnavailableDesktopAssetsPort implements DesktopAssetsPort {
  const UnavailableDesktopAssetsPort();

  @override
  Future<DesktopServiceResult<DesktopAssetOverview>> loadOverview() async =>
      const DesktopServiceResult<DesktopAssetOverview>.unavailable(
        code: 'DESKTOP_ASSETS_UNAVAILABLE',
        message: '未配置后端，云端资产暂不可用',
      );

  @override
  Future<DesktopServiceResult<DesktopAssetItem>> loadMarkdownDocument() async =>
      const DesktopServiceResult<DesktopAssetItem>.unavailable(
        code: 'DESKTOP_ASSETS_UNAVAILABLE',
        message: '未配置后端，云端资产暂不可用',
      );

  @override
  Future<DesktopServiceResult<DesktopAssetDetail>> loadDetail({
    required String assetType,
    required String assetId,
  }) async => const DesktopServiceResult<DesktopAssetDetail>.unavailable(
    code: 'DESKTOP_ASSETS_UNAVAILABLE',
    message: '未配置后端，云端资产详情暂不可用',
  );

  @override
  Future<DesktopServiceResult<DesktopAssetSyncReceipt>> requestSync() async =>
      const DesktopServiceResult<DesktopAssetSyncReceipt>.unavailable(
        code: 'DESKTOP_ASSETS_UNAVAILABLE',
        message: '未配置后端，无法启动云端资产同步',
      );
}

DesktopServiceResult<T> _failure<T>(ApiResult<dynamic> result) {
  final error = result.error;
  return DesktopServiceResult<T>.failure(
    code: error?.code ?? 'DESKTOP_ASSET_REQUEST_FAILED',
    message: error?.message ?? '资产请求失败',
    retryable: error?.isRetryable ?? false,
  );
}
