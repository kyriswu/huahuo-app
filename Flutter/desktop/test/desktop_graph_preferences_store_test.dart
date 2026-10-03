import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/features/editor/application/desktop_graph_preferences.dart';
import 'package:huahuo_desktop/features/editor/data/desktop_graph_preferences_store.dart';

void main() {
  group('DesktopGraphPreferences', () {
    test('defaults preserve the established graph baseline', () {
      expect(DesktopGraphPreferences.defaults, DesktopGraphPreferences());
      expect(DesktopGraphPreferences.defaults.nodeScale, 1);
      expect(DesktopGraphPreferences.defaults.attractionScale, 1);
      expect(DesktopGraphPreferences.defaults.repulsionScale, 1);
      expect(DesktopGraphPreferences.defaults.dampingScale, 1);
      expect(
        DesktopGraphPreferences.defaults.colorPreset,
        DesktopGraphColorPreset.mistSilver,
      );
    });

    test('force response keeps the baseline and amplifies range extremes', () {
      expect(DesktopGraphPreferences.attractionResponseFor(1), 1);
      expect(DesktopGraphPreferences.repulsionResponseFor(1), 1);
      expect(DesktopGraphPreferences.dampingResponseFor(1), 1);

      expect(
        DesktopGraphPreferences.attractionResponseFor(
          DesktopGraphPreferences.minimumAttractionScale,
        ),
        lessThan(.2),
      );
      expect(
        DesktopGraphPreferences.attractionResponseFor(
          DesktopGraphPreferences.maximumAttractionScale,
        ),
        greaterThan(2.7),
      );
      expect(
        DesktopGraphPreferences.repulsionResponseFor(
          DesktopGraphPreferences.minimumRepulsionScale,
        ),
        lessThan(.1),
      );
      expect(
        DesktopGraphPreferences.repulsionResponseFor(
          DesktopGraphPreferences.maximumRepulsionScale,
        ),
        greaterThan(3),
      );
      expect(
        DesktopGraphPreferences.dampingResponseFor(
          DesktopGraphPreferences.minimumDampingScale,
        ),
        lessThan(.1),
      );
      expect(
        DesktopGraphPreferences.dampingResponseFor(
          DesktopGraphPreferences.maximumDampingScale,
        ),
        greaterThan(2.5),
      );
    });

    test('constructor and copyWith clamp every numeric preference', () {
      final preferences = DesktopGraphPreferences(
        nodeScale: -10,
        attractionScale: double.infinity,
        repulsionScale: double.nan,
        dampingScale: 20,
      );

      expect(preferences.nodeScale, DesktopGraphPreferences.minimumNodeScale);
      expect(
        preferences.attractionScale,
        DesktopGraphPreferences.maximumAttractionScale,
      );
      expect(preferences.repulsionScale, DesktopGraphPreferences.defaultScale);
      expect(
        preferences.dampingScale,
        DesktopGraphPreferences.maximumDampingScale,
      );

      final copied = preferences.copyWith(
        nodeScale: 99,
        repulsionScale: double.negativeInfinity,
        dampingScale: -1,
      );
      expect(copied.nodeScale, DesktopGraphPreferences.maximumNodeScale);
      expect(
        copied.repulsionScale,
        DesktopGraphPreferences.minimumRepulsionScale,
      );
      expect(copied.dampingScale, DesktopGraphPreferences.minimumDampingScale);
    });

    test('JSON round trip retains values and stable preset ID', () {
      final preferences = DesktopGraphPreferences(
        nodeScale: 1.25,
        attractionScale: .8,
        repulsionScale: 1.75,
        dampingScale: .55,
        colorPreset: DesktopGraphColorPreset.nightVoyage,
      );

      expect(
        DesktopGraphPreferences.fromJson(preferences.toJson()),
        preferences,
      );
      expect(preferences.toJson()['colorPreset'], 'night-voyage');
    });

    test('JSON clamps invalid ranges and rejects an unknown preset', () {
      final preferences =
          DesktopGraphPreferences.fromJson(const <String, Object?>{
            'nodeScale': -2,
            'attractionScale': 50,
            'repulsionScale': 'large',
            'dampingScale': -.5,
            'colorPreset': 'downloaded-neon-theme',
          });

      expect(preferences.nodeScale, DesktopGraphPreferences.minimumNodeScale);
      expect(
        preferences.attractionScale,
        DesktopGraphPreferences.maximumAttractionScale,
      );
      expect(preferences.repulsionScale, DesktopGraphPreferences.defaultScale);
      expect(
        preferences.dampingScale,
        DesktopGraphPreferences.minimumDampingScale,
      );
      expect(
        preferences.colorPreset,
        DesktopGraphPreferences.defaultColorPreset,
      );
    });
  });

  group('LocalDesktopGraphPreferencesStore', () {
    late Directory supportDirectory;

    setUp(() async {
      supportDirectory = await Directory.systemTemp.createTemp(
        'huahuo-desktop-graph-',
      );
    });

    tearDown(() async {
      if (await supportDirectory.exists()) {
        await supportDirectory.delete(recursive: true);
      }
    });

    test('round trips a versioned, graph-only settings file', () async {
      final store = LocalDesktopGraphPreferencesStore(
        supportDirectory: () async => supportDirectory,
      );
      final preferences = DesktopGraphPreferences(
        nodeScale: 1.35,
        attractionScale: .7,
        repulsionScale: 1.8,
        dampingScale: 1.2,
        colorPreset: DesktopGraphColorPreset.editorial,
      );

      await store.save(preferences);

      expect(await store.load(), preferences);
      final target = _settingsFile(supportDirectory);
      final payload = jsonDecode(await target.readAsString());
      expect(payload, isA<Map<String, Object?>>());
      expect((payload as Map<String, Object?>)['version'], 1);
      expect(payload['graph'], preferences.toJson());
      expect(
        target.path,
        endsWith(
          'settings${Platform.pathSeparator}'
          'desktop-graph-preferences.json',
        ),
      );
    });

    test('returns defaults for malformed persisted data', () async {
      final store = LocalDesktopGraphPreferencesStore(
        supportDirectory: () async => supportDirectory,
      );
      await store.save(
        DesktopGraphPreferences(colorPreset: DesktopGraphColorPreset.pureInk),
      );
      await _settingsFile(supportDirectory).writeAsString('{not-json');

      expect(await store.load(), DesktopGraphPreferences.defaults);
    });

    test('loads direct legacy data and clamps it', () async {
      final store = LocalDesktopGraphPreferencesStore(
        supportDirectory: () async => supportDirectory,
      );
      final target = _settingsFile(supportDirectory);
      await target.parent.create(recursive: true);
      await target.writeAsString(
        jsonEncode(<String, Object?>{
          'nodeScale': 99,
          'colorPreset': 'unknown',
        }),
      );

      final loaded = await store.load();
      expect(loaded.nodeScale, DesktopGraphPreferences.maximumNodeScale);
      expect(loaded.colorPreset, DesktopGraphPreferences.defaultColorPreset);
    });
  });

  test(
    'preview updates memory without writing and commit persists it',
    () async {
      final store = _MemoryStore();
      final controller = DesktopGraphPreferencesController(store: store);
      addTearDown(controller.dispose);
      final previewed = controller.value.copyWith(
        nodeScale: 1.4,
        colorPreset: DesktopGraphColorPreset.tide,
      );

      controller.preview(previewed);
      await Future<void>.delayed(Duration.zero);

      expect(controller.value, previewed);
      expect(store.saved, isEmpty);

      await controller.commit();
      expect(store.saved, <DesktopGraphPreferences>[previewed]);
      expect(store.value, previewed);
    },
  );

  test(
    'rapid commits remain ordered and leave the latest value durable',
    () async {
      final store = _MemoryStore(saveDelay: const Duration(milliseconds: 5));
      final controller = DesktopGraphPreferencesController(store: store);
      addTearDown(controller.dispose);
      final first = controller.value.copyWith(repulsionScale: .5);
      final second = controller.value.copyWith(repulsionScale: 2);
      final third = controller.value.copyWith(repulsionScale: 1.25);

      await Future.wait<void>(<Future<void>>[
        controller.commit(first),
        controller.commit(second),
        controller.commit(third),
      ]);

      expect(controller.value, third);
      expect(store.saved, <DesktopGraphPreferences>[first, second, third]);
      expect(store.value, third);
      expect(store.maximumConcurrentSaves, 1);
    },
  );

  test('a pending load cannot overwrite a user preview', () async {
    final loadCompleter = Completer<DesktopGraphPreferences>();
    final store = _MemoryStore(loadCompleter: loadCompleter);
    final controller = DesktopGraphPreferencesController(store: store);
    addTearDown(controller.dispose);
    final previewed = controller.value.copyWith(dampingScale: 1.6);

    final load = controller.load();
    controller.preview(previewed);
    loadCompleter.complete(
      DesktopGraphPreferences(
        colorPreset: DesktopGraphColorPreset.mountainMist,
      ),
    );
    await load;

    expect(controller.value, previewed);
  });
}

File _settingsFile(Directory supportDirectory) => File(
  '${supportDirectory.path}${Platform.pathSeparator}settings'
  '${Platform.pathSeparator}${LocalDesktopGraphPreferencesStore.fileName}',
);

final class _MemoryStore implements DesktopGraphPreferencesStore {
  _MemoryStore({this.saveDelay = Duration.zero, this.loadCompleter});

  DesktopGraphPreferences value = DesktopGraphPreferences.defaults;
  final Duration saveDelay;
  final Completer<DesktopGraphPreferences>? loadCompleter;
  final List<DesktopGraphPreferences> saved = <DesktopGraphPreferences>[];
  int _concurrentSaves = 0;
  int maximumConcurrentSaves = 0;

  @override
  Future<DesktopGraphPreferences> load() async =>
      loadCompleter == null ? value : loadCompleter!.future;

  @override
  Future<void> save(DesktopGraphPreferences preferences) async {
    _concurrentSaves += 1;
    if (_concurrentSaves > maximumConcurrentSaves) {
      maximumConcurrentSaves = _concurrentSaves;
    }
    if (saveDelay > Duration.zero) await Future<void>.delayed(saveDelay);
    saved.add(preferences);
    value = preferences;
    _concurrentSaves -= 1;
  }
}
