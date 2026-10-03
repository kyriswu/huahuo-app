import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/navigation/pending_navigation_controller.dart';

void main() {
  group('PendingNavigationController', () {
    test('retains a safe V3 destination until it is consumed', () {
      final controller = PendingNavigationController();
      addTearDown(controller.dispose);
      final createdAt = DateTime.utc(2026, 8, 12, 1, 2, 3);

      expect(
        controller.stage(
          location: '/v3/feed/items/note-1?stage=raw',
          reason: PendingNavigationReason.deepLink,
          createdAt: createdAt,
        ),
        isTrue,
      );
      expect(controller.pending?.location, '/v3/feed/items/note-1?stage=raw');
      expect(controller.pending?.reason, PendingNavigationReason.deepLink);
      expect(controller.pending?.createdAt, createdAt);

      final consumed = controller.consume();
      expect(consumed?.location, '/v3/feed/items/note-1?stage=raw');
      expect(controller.pending, isNull);
    });

    test('rejects non-V3, authority, and fragment locations', () {
      final controller = PendingNavigationController();
      addTearDown(controller.dispose);

      for (final location in <String>[
        '/auth',
        'https://example.test/v3/feed',
        '//example.test/v3/feed',
        '/v3/feed#discard',
      ]) {
        expect(
          controller.stage(
            location: location,
            reason: PendingNavigationReason.deepLink,
          ),
          isFalse,
        );
      }
      expect(controller.pending, isNull);
    });

    test('new valid ingress replaces an older pending destination', () {
      final controller = PendingNavigationController();
      addTearDown(controller.dispose);

      controller.stage(
        location: '/v3/feed/graph',
        reason: PendingNavigationReason.deepLink,
      );
      controller.stage(
        location: '/v3/feed/import/documents',
        reason: PendingNavigationReason.externalShare,
      );

      expect(controller.pending?.location, '/v3/feed/import/documents');
      expect(controller.pending?.reason, PendingNavigationReason.externalShare);
    });

    test('retains every canonical widget action route through login', () {
      final controller = PendingNavigationController();
      addTearDown(controller.dispose);
      const locations = <String>[
        '/v3/workbench/canvas',
        '/v3/feed/note',
        '/v3/recording-card',
        '/v3/profile/assets',
        '/v3/workbench',
      ];

      for (final location in locations) {
        expect(
          controller.stage(
            location: location,
            reason: PendingNavigationReason.deepLink,
          ),
          isTrue,
        );
        expect(controller.consume()?.location, location);
      }
    });

    test(
      'stages a protected destination before any non-V3 lifecycle redirect',
      () {
        for (final redirectedLocation in <String>[
          '/splash',
          '/auth',
          '/workspace-retry',
          '/onboarding',
        ]) {
          expect(
            shouldStagePendingNavigation(
              currentLocation: '/v3/feed/items/note-1?stage=raw',
              redirectedLocation: redirectedLocation,
            ),
            isTrue,
          );
        }

        expect(
          shouldStagePendingNavigation(
            currentLocation: '/help',
            redirectedLocation: '/auth',
          ),
          isFalse,
        );
        expect(
          shouldStagePendingNavigation(
            currentLocation: '/v3/feed/items/note-1',
            redirectedLocation: '/v3',
          ),
          isFalse,
        );
      },
    );
  });
}
