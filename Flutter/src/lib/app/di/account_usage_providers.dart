import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/billing/domain/account_usage_repository.dart';
import '../../features/billing/data/account_usage_repository.dart';
import '../../features/billing/application/account_usage_controller.dart';

// resident-provider: Shares one account usage repository for the full account session.
final accountUsageRepositoryProvider = Provider<AccountUsageRepository>((ref) {
  return const UnavailableAccountUsageRepository();
});

// resident-provider: Preserves the account usage controller state machine across route transitions.
final accountUsageControllerProvider =
    ChangeNotifierProvider<AccountUsageController>((ref) {
      return AccountUsageController(
        repository: ref.watch(accountUsageRepositoryProvider),
      );
    });
