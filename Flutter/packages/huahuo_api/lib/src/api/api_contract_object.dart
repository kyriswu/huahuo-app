import 'api_envelope.dart';

final class ApiContractObject {
  ApiContractObject(Map<String, Object?> fields)
    : fields = Map<String, Object?>.unmodifiable(fields);

  factory ApiContractObject.fromValue(Object? value) {
    final object = asObjectMap(value);
    if (object == null) {
      throw const FormatException('Expected an API object');
    }
    return ApiContractObject(object);
  }

  final Map<String, Object?> fields;

  String requireString(String key) {
    final value = fields[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$key must be a non-empty string');
    }
    return value;
  }

  String? optionalString(String key) {
    final value = fields[key];
    if (value == null) return null;
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$key must be a non-empty string when present');
    }
    return value;
  }
}

final class ApiContractPage {
  const ApiContractPage({required this.items, this.nextCursor});

  factory ApiContractPage.fromValue(
    Object? value, {
    String itemsKey = 'items',
  }) {
    final object = asObjectMap(value);
    final rawItems = object?[itemsKey];
    if (object == null || rawItems is! List) {
      throw FormatException('$itemsKey must be a list');
    }
    final items = <ApiContractObject>[];
    for (final item in rawItems) {
      items.add(ApiContractObject.fromValue(item));
    }
    final nextCursor = object['nextCursor'];
    if (nextCursor != null && nextCursor is! String) {
      throw const FormatException('nextCursor must be a string');
    }
    return ApiContractPage(
      items: List<ApiContractObject>.unmodifiable(items),
      nextCursor: nextCursor as String?,
    );
  }

  final List<ApiContractObject> items;
  final String? nextCursor;
}
