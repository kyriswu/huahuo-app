import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/database/app_preferences_dao.dart';
import '../../../core/native/recording_card_native_port.dart';
import '../domain/recording_card_connection_history.dart';

final class RecordingCardConnectionHistoryStore
    implements RecordingCardConnectionHistoryPort {
  RecordingCardConnectionHistoryStore({
    required AppPreferencesDao preferences,
    required String accountScope,
  }) : // Public collaborator names intentionally omit private field prefixes.
       // ignore: prefer_initializing_formals
       _preferences = preferences,
       _scopeHash = _scopeHashFor(accountScope) {
    if (accountScope.trim().isEmpty) {
      throw ArgumentError.value(
        accountScope,
        'accountScope',
        'must not be empty',
      );
    }
  }

  static const maximumEntries = 4;
  static const _schemaVersion = 1;

  final AppPreferencesDao _preferences;
  final String _scopeHash;

  String get _preferenceKey =>
      'recording-card-connection-history:${_scopeHash.substring(0, 24)}';

  @override
  List<RecordingCardConnectionHistoryEntry> load() {
    final encoded = _preferences.readValue(_preferenceKey);
    if (encoded == null) return const <RecordingCardConnectionHistoryEntry>[];
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, Object?> ||
          decoded['schema'] != _schemaVersion ||
          decoded['entries'] is! List<Object?>) {
        return const <RecordingCardConnectionHistoryEntry>[];
      }
      final deduplicated = <String, RecordingCardConnectionHistoryEntry>{};
      for (final rawEntry in decoded['entries']! as List<Object?>) {
        final entry = _parseEntry(rawEntry);
        if (entry == null) continue;
        final existing = deduplicated[entry.safeDeviceFingerprint];
        if (existing == null ||
            entry.lastConnectedAt.isAfter(existing.lastConnectedAt)) {
          deduplicated[entry.safeDeviceFingerprint] = entry;
        }
      }
      final entries = deduplicated.values.toList(growable: false)
        ..sort(
          (left, right) =>
              right.lastConnectedAt.compareTo(left.lastConnectedAt),
        );
      return List<RecordingCardConnectionHistoryEntry>.unmodifiable(
        entries.take(maximumEntries),
      );
    } on FormatException {
      return const <RecordingCardConnectionHistoryEntry>[];
    } on TypeError {
      return const <RecordingCardConnectionHistoryEntry>[];
    } on Object {
      return const <RecordingCardConnectionHistoryEntry>[];
    }
  }

  @override
  void remember(RecordingCardConnectionHistoryEntry entry) {
    final normalized = _normalizeEntry(entry);
    if (normalized == null) return;
    final entries =
        <RecordingCardConnectionHistoryEntry>[
          normalized,
          for (final existing in load())
            if (existing.safeDeviceFingerprint !=
                normalized.safeDeviceFingerprint)
              existing,
        ]..sort(
          (left, right) =>
              right.lastConnectedAt.compareTo(left.lastConnectedAt),
        );
    _preferences.upsertValue(
      preferenceKey: _preferenceKey,
      value: jsonEncode(<String, Object?>{
        'schema': _schemaVersion,
        'entries': <Map<String, Object?>>[
          for (final item in entries.take(maximumEntries))
            <String, Object?>{
              'displayName': item.displayName,
              'safeDeviceFingerprint': item.safeDeviceFingerprint,
              'lastConnectedAt': item.lastConnectedAt.toUtc().toIso8601String(),
            },
        ],
      }),
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
  }

  static RecordingCardConnectionHistoryEntry? _parseEntry(Object? raw) {
    if (raw is! Map<Object?, Object?>) return null;
    final displayName = raw['displayName'];
    final fingerprint = raw['safeDeviceFingerprint'];
    final lastConnectedAt = raw['lastConnectedAt'];
    if (displayName is! String ||
        fingerprint is! String ||
        lastConnectedAt is! String) {
      return null;
    }
    final parsedAt = DateTime.tryParse(lastConnectedAt)?.toUtc();
    if (parsedAt == null) return null;
    return _normalizeEntry(
      RecordingCardConnectionHistoryEntry(
        displayName: displayName,
        safeDeviceFingerprint: fingerprint,
        lastConnectedAt: parsedAt,
      ),
    );
  }

  static RecordingCardConnectionHistoryEntry? _normalizeEntry(
    RecordingCardConnectionHistoryEntry entry,
  ) {
    final displayName = entry.displayName.trim();
    final fingerprint = entry.safeDeviceFingerprint.trim();
    if (!isSafeRecordingCardIdentifier(displayName) ||
        !isSafeRecordingCardIdentifier(fingerprint)) {
      return null;
    }
    return RecordingCardConnectionHistoryEntry(
      displayName: displayName,
      safeDeviceFingerprint: fingerprint,
      lastConnectedAt: entry.lastConnectedAt.toUtc(),
    );
  }

  static String _scopeHashFor(String accountScope) =>
      sha256.convert(utf8.encode(accountScope.trim())).toString();
}
