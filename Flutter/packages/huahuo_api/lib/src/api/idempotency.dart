import 'endpoint_catalog.dart';
import 'api_envelope.dart';

final class SubmissionKeyRecord {
  const SubmissionKeyRecord({
    required this.operation,
    required this.key,
    required this.createdAt,
    this.businessEntityId,
    this.localDraftId,
    this.scene,
    this.retiredAt,
  });

  final String operation;
  final String key;
  final DateTime createdAt;
  final String? businessEntityId;
  final String? localDraftId;
  final String? scene;
  final DateTime? retiredAt;

  SubmissionKeyRecord retire(DateTime retiredAt) {
    return SubmissionKeyRecord(
      operation: operation,
      key: key,
      createdAt: createdAt,
      businessEntityId: businessEntityId,
      localDraftId: localDraftId,
      scene: scene,
      retiredAt: retiredAt,
    );
  }
}

final class SubmissionKeyStore {
  const SubmissionKeyStore({this.records = const <SubmissionKeyRecord>[]});

  final List<SubmissionKeyRecord> records;

  static const empty = SubmissionKeyStore();

  SubmissionKeyStore add(SubmissionKeyRecord record) {
    return SubmissionKeyStore(
      records: List<SubmissionKeyRecord>.unmodifiable(<SubmissionKeyRecord>[
        ...records,
        record,
      ]),
    );
  }

  SubmissionKeyStore replaceRecords(List<SubmissionKeyRecord> nextRecords) {
    return SubmissionKeyStore(
      records: List<SubmissionKeyRecord>.unmodifiable(nextRecords),
    );
  }
}

final class IdempotencyRequestContext {
  const IdempotencyRequestContext({
    this.explicitKey,
    this.operation,
    this.businessEntityId,
    this.localDraftId,
    this.scene,
    this.automaticRetry = false,
    this.now,
    this.generateKey,
  });

  final String? explicitKey;
  final String? operation;
  final String? businessEntityId;
  final String? localDraftId;
  final String? scene;
  final bool automaticRetry;
  final DateTime? now;
  final String Function()? generateKey;

  bool get hasOperation => operation != null && operation!.isNotEmpty;
}

final class IdempotencyResolution {
  const IdempotencyResolution._({
    required this.ok,
    required this.store,
    this.header,
    this.error,
  });

  factory IdempotencyResolution.success({
    String? header,
    required SubmissionKeyStore store,
  }) {
    return IdempotencyResolution._(ok: true, header: header, store: store);
  }

  factory IdempotencyResolution.failure({
    required AppFailure error,
    required SubmissionKeyStore store,
  }) {
    return IdempotencyResolution._(ok: false, error: error, store: store);
  }

  final bool ok;
  final String? header;
  final AppFailure? error;
  final SubmissionKeyStore store;
}

({String key, SubmissionKeyStore store}) createSubmissionKey(
  SubmissionKeyStore store,
  IdempotencyRequestContext context,
) {
  if (!context.hasOperation) {
    throw ArgumentError('operation is required to create an idempotency key');
  }
  final key = context.generateKey?.call() ?? _defaultKey();
  final record = SubmissionKeyRecord(
    operation: context.operation!,
    businessEntityId: context.businessEntityId,
    localDraftId: context.localDraftId,
    scene: context.scene,
    key: key,
    createdAt: context.now ?? DateTime.now().toUtc(),
  );
  return (key: key, store: store.add(record));
}

String? reuseSubmissionKey(
  SubmissionKeyStore store,
  IdempotencyRequestContext context,
) {
  if (!context.hasOperation) {
    return null;
  }
  for (final record in store.records.reversed) {
    if (record.retiredAt == null &&
        record.operation == context.operation &&
        record.businessEntityId == context.businessEntityId &&
        record.localDraftId == context.localDraftId &&
        record.scene == context.scene) {
      return record.key;
    }
  }
  return null;
}

SubmissionKeyStore retireSubmissionKey(
  SubmissionKeyStore store,
  IdempotencyRequestContext context,
) {
  if (!context.hasOperation) {
    return store;
  }
  final retiredAt = context.now ?? DateTime.now().toUtc();
  return store.replaceRecords(<SubmissionKeyRecord>[
    for (final record in store.records)
      if (record.retiredAt == null &&
          record.operation == context.operation &&
          record.businessEntityId == context.businessEntityId &&
          record.localDraftId == context.localDraftId &&
          record.scene == context.scene)
        record.retire(retiredAt)
      else
        record,
  ]);
}

IdempotencyResolution resolveIdempotencyKeyForEndpoint(
  EndpointDefinition endpoint,
  SubmissionKeyStore store, [
  IdempotencyRequestContext context = const IdempotencyRequestContext(),
]) {
  if (endpoint.idempotency == EndpointIdempotencyPolicy.forbidden) {
    return IdempotencyResolution.success(store: store);
  }

  final explicitKey = context.explicitKey;
  if (explicitKey != null && explicitKey.isNotEmpty) {
    return IdempotencyResolution.success(header: explicitKey, store: store);
  }

  if (context.automaticRetry) {
    final reusable = reuseSubmissionKey(store, context);
    if (reusable != null) {
      return IdempotencyResolution.success(header: reusable, store: store);
    }
  }

  if (context.hasOperation) {
    final created = createSubmissionKey(store, context);
    return IdempotencyResolution.success(
      header: created.key,
      store: created.store,
    );
  }

  if (endpoint.idempotency == EndpointIdempotencyPolicy.required) {
    return IdempotencyResolution.failure(
      store: store,
      error: AppFailure(
        code: 'IDEMPOTENCY_KEY_REQUIRED',
        category: AppFailureCategory.api,
        message: 'Idempotency key is required before executing this request',
        userMessageKey: 'api.error.idempotencyRequired',
        recoveryActions: const <String>['none'],
        metadata: <String, Object?>{'endpointId': endpoint.id},
      ),
    );
  }

  return IdempotencyResolution.success(store: store);
}

List<String> assertIdempotencyPolicy(EndpointDefinition endpoint) {
  return assertEndpointPolicy(endpoint);
}

bool idempotencyPolicyAllowsHeader(EndpointIdempotencyPolicy policy) {
  return policy != EndpointIdempotencyPolicy.forbidden;
}

int _counter = 0;

String _defaultKey() {
  _counter += 1;
  return 'idem-${DateTime.now().toUtc().microsecondsSinceEpoch}-$_counter';
}
