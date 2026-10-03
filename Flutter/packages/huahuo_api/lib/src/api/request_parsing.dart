import 'api_contract_object.dart';
import 'api_envelope.dart';

ApiContractObject? parseApiObject(Object? value) {
  final object = asObjectMap(value);
  return object == null ? null : ApiContractObject(object);
}

T? parseJsonModel<T>(Object? value, T Function(Map<String, Object?>) parser) {
  final object = asObjectMap(value);
  return object == null ? null : parser(object);
}

String requiredClientText(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, 'Value must not be empty');
  }
  return normalized;
}

int boundedPageLimit(int value) {
  if (value < 1 || value > 100) {
    throw ArgumentError.value(value, 'limit', 'Expected a value from 1 to 100');
  }
  return value;
}

Map<String, String> ifMatchHeaders(String etag) {
  final normalized = etag.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(etag, 'etag', 'If-Match must not be empty');
  }
  return <String, String>{'If-Match': normalized};
}
