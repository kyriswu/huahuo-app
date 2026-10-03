import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_hub_controller.dart';
import 'package:huahuoai_app/features/ui_v3/domain/profile_activity_models.dart';

void main() {
  test('removes only activities belonging to a deleted memory note', () {
    final controller = ProfileHubController(
      referenceDay: DateTime(2026, 7, 13),
    );
    controller.recordActivity(
      V3ProfileActivity(
        id: 'deleted-note-activity',
        occurredAt: DateTime(2026, 7, 13, 9),
        type: V3ProfileActivityType.raw,
        title: '待删除笔记',
        feedItemId: 'deleted-note',
      ),
    );
    controller.recordActivity(
      V3ProfileActivity(
        id: 'retained-note-activity',
        occurredAt: DateTime(2026, 7, 13, 10),
        type: V3ProfileActivityType.raw,
        title: '保留笔记',
        feedItemId: 'retained-note',
      ),
    );

    expect(controller.removeActivitiesForNote('deleted-note'), 1);
    expect(
      controller.activities.where(
        (activity) => activity.feedItemId == 'deleted-note',
      ),
      isEmpty,
    );
    expect(
      controller.activities.where(
        (activity) => activity.feedItemId == 'retained-note',
      ),
      hasLength(1),
    );
  });
}
