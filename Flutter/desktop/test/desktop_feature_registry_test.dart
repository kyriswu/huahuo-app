import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_product/huahuo_product.dart';

import 'package:huahuo_desktop/app/desktop_feature_registry.dart';

void main() {
  test('Desktop provider exposes only enabled shared commands', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final state = await container.read(desktopFeatureRegistryProvider.future);
    final commands = container.read(desktopFeatureCommandsProvider);

    expect(state.status, FeatureRegistryStatus.ready);
    expect(state.errorCode, isNull);
    expect(commands, isNotEmpty);
    expect(
      commands.map((command) => command.id.value),
      isNot(contains(startsWith('native.'))),
    );
    expect(
      commands.map((command) => command.location),
      containsAll(<String>[
        '/brain',
        '/chat',
        '/recordings',
        '/support',
        '/settings',
        '/account/digital-twin',
      ]),
    );
  });
}
