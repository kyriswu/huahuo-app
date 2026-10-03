import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/source_reachability_check.dart';

void main() {
  final root = Directory('lib').absolute;
  final apiRoot = Directory('../packages/huahuo_api/lib').absolute;
  final graph = buildWorkspaceDependencyGraph(
    {
      for (final file in root.listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart')) file.path: file.readAsStringSync(),
      for (final file in apiRoot.listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart')) file.path: file.readAsStringSync(),
    },
    {'huahuoai_app': root.path, 'huahuo_api': apiRoot.path},
  );

  Set<String> dependenciesOf(String relativePath) {
    final entry = '${root.path}/$relativePath';
    expect(graph, contains(entry));
    final visited = <String>{};
    final pending = <String>[entry];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (!visited.add(current)) continue;
      pending.addAll(graph[current] ?? const <String>{});
    }
    return visited;
  }

  test('onboarding application can be imported without app composition', () {
    final application = Directory(
      '${root.path}/features/onboarding/application',
    );
    final controllers = application.listSync().whereType<File>().where(
      (file) => file.path.endsWith('.dart'),
    );
    expect(controllers, isNotEmpty);
    for (final controller in controllers) {
      final dependencies = dependenciesOf(
        controller.path.substring(root.path.length + 1),
      );
      expect(
        dependencies.where((path) => path.startsWith('${root.path}/app/')),
        isEmpty,
        reason: '${controller.path} must receive app services by injection',
      );
    }
  });

  test('global providers cannot import onboarding composition back', () {
    expect(
      dependenciesOf('app/bootstrap/app_providers.dart'),
      isNot(contains('${root.path}/app/di/onboarding_providers.dart')),
    );
  });

  test('billing purchase application is independent of app composition', () {
    final dependencies = dependenciesOf(
      'features/billing/application/billing_controller.dart',
    );
    expect(
      dependencies.where((path) => path.startsWith('${root.path}/app/')),
      isEmpty,
    );
  });

  test('global providers cannot import billing composition back', () {
    expect(
      dependenciesOf('app/bootstrap/app_providers.dart'),
      isNot(contains('${root.path}/app/di/billing_providers.dart')),
    );
  });

  test('account usage controller depends only on its repository contract', () {
    final dependencies = dependenciesOf(
      'features/billing/application/account_usage_controller.dart',
    );
    expect(
      dependencies.where(
        (path) =>
            path.contains('/app/') ||
            path.contains('/data/') ||
            path.contains('/huahuo_api/'),
      ),
      isEmpty,
      reason: 'Controller must not reach composition, remote data or API DTOs',
    );
  });

  test('account usage domain cannot depend on another layer', () {
    final domain = '${root.path}/features/billing/domain/';
    for (final file in Directory(domain).listSync().whereType<File>()) {
      final dependencies = dependenciesOf(
        file.path.substring(root.path.length + 1),
      );
      expect(
        dependencies.where((path) => !path.startsWith(domain)),
        isEmpty,
        reason: '${file.path} must remain a repository contract or value',
      );
    }
  });

  test(
    'chat controller consumes the domain contract instead of remote data',
    () {
      final dependencies = dependenciesOf(
        'features/chat/application/chat_controller.dart',
      );
      expect(
        dependencies,
        isNot(contains('${root.path}/features/chat/data/chat_api.dart')),
        reason: 'ChatController must not import the concrete remote adapter',
      );
    },
  );
}
