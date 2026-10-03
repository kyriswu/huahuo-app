import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/sphere_graph_motion_controller.dart';

void main() {
  testWidgets('idle expires without frames and policy cannot restart it', (
    tester,
  ) async {
    var updates = 0;
    final motion = SphereGraphMotionController(
      onRotate: (_) => updates++,
      now: tester.binding.clock.now,
    );
    motion.configure(active: true, suspended: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(updates, 1);
    await tester.pump(const Duration(milliseconds: 7900));
    expect(motion.state, SphereGraphMotionState.idle);
    expect(motion.isTicking, isFalse);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
    final idleUpdates = updates;
    motion.configure(active: true, suspended: false, nodeCount: 10000);
    motion.configure(active: true, suspended: true);
    motion.configure(active: true, suspended: false, maximumFrameRate: 15);
    await tester.pump(const Duration(minutes: 1));
    expect(motion.state, SphereGraphMotionState.idle);
    expect(updates, idleUpdates);
    expect(tester.binding.hasScheduledFrame, isFalse);
    motion.dispose();
  });

  testWidgets('touch and visible entry each receive one bounded window', (
    tester,
  ) async {
    final motion = SphereGraphMotionController(
      onRotate: (_) {},
      now: tester.binding.clock.now,
    );
    motion.configure(active: true, suspended: false);
    await tester.pump(const Duration(seconds: 8));
    expect(motion.state, SphereGraphMotionState.idle);
    motion.pointerDown(1);
    motion.pointerUp(1);
    await tester.pump(const Duration(seconds: 2));
    expect(motion.state, SphereGraphMotionState.automatic);
    await tester.pump(const Duration(seconds: 8));
    expect(motion.state, SphereGraphMotionState.idle);
    motion.configure(active: false, suspended: false);
    motion.configure(active: true, suspended: false);
    expect(motion.state, SphereGraphMotionState.automatic);
    motion.dispose();
    await tester.pump(const Duration(seconds: 10));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('suspension does not extend the automatic deadline', (
    tester,
  ) async {
    final motion = SphereGraphMotionController(
      onRotate: (_) {},
      now: tester.binding.clock.now,
    );
    motion.configure(active: true, suspended: false);
    await tester.pump(const Duration(seconds: 3));
    motion.configure(active: true, suspended: true);
    await tester.pump(const Duration(seconds: 6));
    motion.configure(active: true, suspended: false);
    expect(motion.state, SphereGraphMotionState.idle);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
    motion.dispose();
  });

  testWidgets(
    'visible sphere rotates and resumes two seconds after final touch',
    (tester) async {
      var rotation = 0.0;
      final motion = SphereGraphMotionController(
        onRotate: (delta) => rotation += delta,
      );
      expect(motion.isTicking, isFalse);
      motion.configure(active: true, suspended: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(rotation, greaterThan(0));
      motion.pointerDown(1);
      motion.pointerDown(2);
      final heldRotation = rotation;
      expect(motion.state, SphereGraphMotionState.interacting);
      expect(motion.isTicking, isFalse);
      motion.pointerUp(1);
      await tester.pump(const Duration(seconds: 3));
      expect(rotation, heldRotation);
      motion.pointerUp(2);
      expect(motion.state, SphereGraphMotionState.cooldown);
      await tester.pump(const Duration(milliseconds: 1900));
      expect(motion.isTicking, isFalse);
      motion.pointerDown(3);
      motion.pointerUp(3);
      await tester.pump(const Duration(milliseconds: 1900));
      expect(motion.isTicking, isFalse);
      await tester.pump(const Duration(milliseconds: 100));
      expect(motion.state, SphereGraphMotionState.automatic);
      await tester.pump(const Duration(milliseconds: 100));
      expect(rotation, greaterThan(heldRotation));
      motion.dispose();
    },
  );

  testWidgets(
    'hiding, suspension and disposal release ticker and resume timer',
    (tester) async {
      var rotation = 0.0;
      final motion = SphereGraphMotionController(
        onRotate: (delta) => rotation += delta,
      );
      motion.configure(active: true, suspended: false);
      await tester.pump();
      motion.pointerDown(1);
      motion.pointerUp(1);
      motion.configure(active: false, suspended: false);
      await tester.pump(const Duration(seconds: 20));
      expect(motion.state, SphereGraphMotionState.inactive);
      expect(motion.isTicking, isFalse);
      expect(rotation, 0);
      motion.configure(active: true, suspended: true);
      expect(motion.state, SphereGraphMotionState.suspended);
      expect(motion.isTicking, isFalse);
      motion.configure(active: true, suspended: false);
      await tester.pump();
      expect(rotation, 0);
      await tester.pump(const Duration(milliseconds: 40));
      expect(rotation, inExclusiveRange(0, .01));
      motion.pointerDown(2);
      motion.pointerUp(2);
      motion.dispose();
      await tester.pump(const Duration(seconds: 3));
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets(
    'cadence waits without scheduling display frames and obeys policy',
    (tester) async {
      var updates = 0;
      final motion = SphereGraphMotionController(onRotate: (_) => updates++);
      addTearDown(motion.dispose);
      motion.configure(active: true, suspended: false, maximumFrameRate: 10);
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pump(const Duration(milliseconds: 99));
      expect(updates, 0);
      await tester.pump(const Duration(milliseconds: 1));
      expect(updates, 1);
      expect(tester.binding.transientCallbackCount, 0);
      motion.pointerDown(1);
      motion.pointerUp(1);
      await tester.pump(const Duration(seconds: 1));
      motion.configure(active: true, suspended: false, maximumFrameRate: 15);
      await tester.pump(const Duration(seconds: 1));
      expect(motion.state, SphereGraphMotionState.automatic);
      motion.configure(active: true, suspended: false, maximumFrameRate: 0);
      await tester.pump(const Duration(seconds: 5));
      expect(motion.state, SphereGraphMotionState.suspended);
      expect(updates, 1);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );
}
