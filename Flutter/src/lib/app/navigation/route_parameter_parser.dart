import '../../features/assets/data/asset_api.dart';
import '../../features/ui_v3/domain/knowledge_library_models.dart';

String? routeCanvasTopicId(String? value) {
  final normalized = value?.trim();
  if (normalized == null ||
      normalized.isEmpty ||
      normalized.length > 128 ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

String? routePhotoAlbumResourceId(String? value) {
  final normalized = value?.trim();
  if (normalized == null ||
      normalized.isEmpty ||
      normalized != value ||
      normalized.length > 160 ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

String? routeCanvasTopicTitle(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  return normalized.length <= 120 ? normalized : normalized.substring(0, 120);
}

AssetMarkdownFocus? routeAssetFocus(String? value) => switch (value) {
  'overview' => AssetMarkdownFocus.overview,
  'content_line' => AssetMarkdownFocus.contentLine,
  'recording' => AssetMarkdownFocus.recording,
  'profile' => AssetMarkdownFocus.profile,
  _ => null,
};

DateTime? routeCalendarDate(String? value) {
  if (value == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    return null;
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null ||
      parsed.year.toString().padLeft(4, '0') != value.substring(0, 4) ||
      parsed.month.toString().padLeft(2, '0') != value.substring(5, 7) ||
      parsed.day.toString().padLeft(2, '0') != value.substring(8, 10)) {
    return null;
  }
  return DateTime(parsed.year, parsed.month, parsed.day);
}

KnowledgeChannel? routeKnowledgeChannel(String? value) {
  final normalized = value?.trim();
  if (normalized == null ||
      normalized.isEmpty ||
      normalized.length > 32 ||
      normalized != value) {
    return null;
  }
  return KnowledgeChannel.fromId(normalized);
}

String? routeKnowledgePublicationId(String? value) {
  final normalized = value?.trim();
  if (normalized == null ||
      normalized.isEmpty ||
      normalized.length > 128 ||
      normalized != value ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

String? routeKnowledgeWorldQuery(String? value) {
  if (value == null) return '';
  final normalized = value.trim();
  if (normalized.length > 80 ||
      RegExp(r'[\u0000-\u001F\u007F-\u009F]').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}
