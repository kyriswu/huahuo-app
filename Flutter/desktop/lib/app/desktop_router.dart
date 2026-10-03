import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'desktop_feature_registry.dart';

typedef DesktopRoutePageBuilder =
    Widget Function(BuildContext context, String location, bool routeFailed);

GoRouter createDesktopRouter({
  required List<DesktopFeatureCommand> commands,
  required DesktopRoutePageBuilder pageBuilder,
  String initialLocation = '/brain',
}) {
  final locations = commands.map((command) => command.location).toSet();
  final resolvedInitialLocation = locations.contains(initialLocation)
      ? initialLocation
      : '/brain';
  return GoRouter(
    initialLocation: resolvedInitialLocation,
    routes: <RouteBase>[
      ShellRoute(
        pageBuilder: (context, state, child) => NoTransitionPage<void>(
          key: const ValueKey<String>('desktop-workspace-shell'),
          child: pageBuilder(context, state.uri.path, false),
        ),
        routes: <RouteBase>[
          GoRoute(path: '/', redirect: (context, state) => '/brain'),
          for (final location in locations)
            GoRoute(
              path: location,
              pageBuilder: (context, state) =>
                  const NoTransitionPage<void>(child: SizedBox.shrink()),
            ),
        ],
      ),
    ],
    errorBuilder: (context, state) =>
        pageBuilder(context, state.uri.path, true),
  );
}
