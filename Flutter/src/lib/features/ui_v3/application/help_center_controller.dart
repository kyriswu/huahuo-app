import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/help_center_repository.dart';
import '../domain/help_center_models.dart';
import '../domain/profile_capability_models.dart';
import 'profile_capability_controller.dart';

export '../domain/help_center_models.dart' show HelpCenterRepository;

final helpCenterRepositoryProvider = Provider.autoDispose<HelpCenterRepository>(
  (ref) => AssetHelpCenterRepository(),
);

final helpCenterCatalogProvider = FutureProvider.autoDispose<HelpCenterCatalog>(
  (ref) => ref.watch(helpCenterRepositoryProvider).loadCatalog(),
);

final helpArticleProvider = FutureProvider.autoDispose
    .family<HelpArticle, String>(
      (ref, articleId) =>
          ref.watch(helpCenterRepositoryProvider).loadArticle(articleId),
    );

final helpCenterSupportControllerProvider =
    Provider.autoDispose<HelpCenterSupportController>(
      (ref) =>
          HelpCenterSupportController(ref.watch(profileSupportPortProvider)),
    );

final class HelpCenterSupportController {
  const HelpCenterSupportController(this._supportPort);

  final ProfileSupportPort _supportPort;

  Future<ProfileCapabilityResult<bool>> submitBug(
    ProfileBugReportRequest request,
  ) => _supportPort.submitBug(request);
}
