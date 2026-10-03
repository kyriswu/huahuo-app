import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/features/editor/application/desktop_graph_preferences.dart';
import 'package:huahuo_desktop/features/editor/data/desktop_graph_preferences_store.dart';
import 'package:huahuo_desktop/features/editor/presentation/desktop_graph_settings_controls.dart';

void main() {
  Future<void> pumpControls(
    WidgetTester tester,
    DesktopGraphPreferencesController controller,
  ) async {
    tester.view.physicalSize = const Size(900, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: SizedBox(
                width: 720,
                child: DesktopGraphSettingsControls(controller: controller),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('shows every graph parameter, palette, preview, and scope note', (
    tester,
  ) async {
    final controller = DesktopGraphPreferencesController(store: _MemoryStore());
    addTearDown(controller.dispose);
    await pumpControls(tester, controller);

    expect(find.byKey(const ValueKey<String>('graph-node-scale')), findsOne);
    expect(
      find.byKey(const ValueKey<String>('graph-attraction-scale')),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey<String>('graph-repulsion-scale')),
      findsOne,
    );
    expect(find.byKey(const ValueKey<String>('graph-damping-scale')), findsOne);
    expect(find.text('实时力场预览'), findsOne);
    expect(find.textContaining('所有 2D 图谱'), findsOne);
    for (final preset in DesktopGraphColorPreset.values) {
      expect(
        find.byKey(ValueKey<String>('graph-palette-${preset.storageValue}')),
        findsOne,
      );
    }
  });

  testWidgets('slider previews in memory and persists only on change end', (
    tester,
  ) async {
    final store = _MemoryStore();
    final controller = DesktopGraphPreferencesController(store: store);
    addTearDown(controller.dispose);
    await pumpControls(tester, controller);

    final sliderFinder = find.byKey(
      const ValueKey<String>('graph-repulsion-scale'),
    );
    final slider = tester.widget<Slider>(sliderFinder);
    slider.onChanged!(1.8);
    await tester.pump();

    expect(controller.value.repulsionScale, 1.8);
    expect(store.saved, isEmpty);

    tester.widget<Slider>(sliderFinder).onChangeEnd!(1.8);
    await tester.pump();

    expect(store.saved, hasLength(1));
    expect(store.saved.single.repulsionScale, 1.8);
  });

  testWidgets('palette selection persists and reset restores all defaults', (
    tester,
  ) async {
    final store = _MemoryStore();
    final controller = DesktopGraphPreferencesController(store: store);
    addTearDown(controller.dispose);
    await pumpControls(tester, controller);

    await tester.tap(
      find.byKey(const ValueKey<String>('graph-palette-night-voyage')),
    );
    await tester.pump();

    expect(controller.value.colorPreset, DesktopGraphColorPreset.nightVoyage);
    expect(store.saved.last.colorPreset, DesktopGraphColorPreset.nightVoyage);

    await tester.tap(
      find.byKey(const ValueKey<String>('graph-palette-ego-pulse')),
    );
    await tester.pump();

    expect(controller.value.colorPreset, DesktopGraphColorPreset.egoPulse);
    expect(store.saved.last.colorPreset, DesktopGraphColorPreset.egoPulse);

    await tester.tap(
      find.byKey(const ValueKey<String>('graph-preferences-reset')),
    );
    await tester.pump();

    expect(controller.value, DesktopGraphPreferences.defaults);
    expect(store.saved.last, DesktopGraphPreferences.defaults);
  });
}

final class _MemoryStore implements DesktopGraphPreferencesStore {
  DesktopGraphPreferences value = DesktopGraphPreferences.defaults;
  final List<DesktopGraphPreferences> saved = <DesktopGraphPreferences>[];

  @override
  Future<DesktopGraphPreferences> load() async => value;

  @override
  Future<void> save(DesktopGraphPreferences preferences) async {
    value = preferences;
    saved.add(preferences);
  }
}
