// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/database/app_preferences_dao.dart';

abstract interface class BillingPendingOrderStore {
  String? read(String userScope);

  void save(String userScope, String orderId);

  void clear(String userScope);
}

final class AppPreferencesBillingPendingOrderStore
    implements BillingPendingOrderStore {
  AppPreferencesBillingPendingOrderStore({
    required AppPreferencesDao preferences,
    DateTime Function()? now,
  }) : _preferences = preferences,
       _now = now ?? DateTime.now;

  final AppPreferencesDao _preferences;
  final DateTime Function() _now;

  @override
  String? read(String userScope) {
    final value = _preferences.readValue(_key(userScope));
    return value != null && _safeID.hasMatch(value) ? value : null;
  }

  @override
  void save(String userScope, String orderId) {
    if (!_safeID.hasMatch(orderId)) {
      throw ArgumentError.value(orderId, 'orderId', 'must be a safe ID');
    }
    _preferences.upsertValue(
      preferenceKey: _key(userScope),
      value: orderId,
      updatedAt: _now().toUtc().toIso8601String(),
    );
  }

  @override
  void clear(String userScope) => _preferences.deleteValue(_key(userScope));

  String _key(String userScope) {
    final normalized = userScope.trim();
    if (normalized.isEmpty || normalized == 'anonymous') {
      throw ArgumentError.value(
        userScope,
        'userScope',
        'must be authenticated',
      );
    }
    final digest = sha256.convert(utf8.encode(normalized));
    return 'billing-pending-order-${digest.toString().substring(0, 24)}';
  }
}

final _safeID = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$');
