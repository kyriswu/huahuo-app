import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/recording_card/data/recording_card_connection_history_store.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_connection_history.dart';

void main() {
  group('RecordingCardConnectionHistoryStore', () {
    test('keeps safe entries account-scoped, deduplicated and bounded', () {
      final database = AppDatabase();
      final preferences = AppPreferencesDao(database);
      final accountA = RecordingCardConnectionHistoryStore(
        preferences: preferences,
        accountScope: 'account-a',
      );
      final accountB = RecordingCardConnectionHistoryStore(
        preferences: preferences,
        accountScope: 'account-b',
      );
      final base = DateTime.utc(2026, 8, 19, 10);

      for (
        var index = 0;
        index < RecordingCardConnectionHistoryStore.maximumEntries + 1;
        index += 1
      ) {
        accountA.remember(
          RecordingCardConnectionHistoryEntry(
            displayName: '无限花火录音卡 $index',
            safeDeviceFingerprint: 'recording-card-$index',
            lastConnectedAt: base.add(Duration(minutes: index)),
          ),
        );
      }
      accountA.remember(
        RecordingCardConnectionHistoryEntry(
          displayName: '新名称',
          safeDeviceFingerprint: 'recording-card-1',
          lastConnectedAt: base.add(const Duration(hours: 1)),
        ),
      );

      final entries = accountA.load();
      expect(
        entries,
        hasLength(RecordingCardConnectionHistoryStore.maximumEntries),
      );
      expect(entries.first.safeDeviceFingerprint, 'recording-card-1');
      expect(entries.first.displayName, '新名称');
      expect(
        entries.where(
          (entry) => entry.safeDeviceFingerprint == 'recording-card-1',
        ),
        hasLength(1),
      );
      expect(accountB.load(), isEmpty);
    });

    test('ignores malformed persisted payloads', () {
      final database = AppDatabase();
      final preferences = AppPreferencesDao(database);
      final store = RecordingCardConnectionHistoryStore(
        preferences: preferences,
        accountScope: 'account-a',
      );
      store.remember(
        RecordingCardConnectionHistoryEntry(
          displayName: '录音卡',
          safeDeviceFingerprint: 'recording-card-a',
          lastConnectedAt: DateTime.utc(2026, 8, 19),
        ),
      );
      final preferenceKey =
          preferences.listPreferences().single['preference_key'] as String;
      preferences.upsertValue(
        preferenceKey: preferenceKey,
        value: '{not-json',
        updatedAt: DateTime.utc(2026, 8, 19).toIso8601String(),
      );

      expect(store.load(), isEmpty);
    });
  });
}
