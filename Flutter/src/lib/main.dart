import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'app/bootstrap/app_providers.dart';
import 'app/bootstrap/app_root.dart';
import 'app/bootstrap/app_runtime_activation.dart';
import 'app/bootstrap/asset_projection_cache_scope.dart';
import 'app/bootstrap/home_widget_snapshot_sync.dart';
import 'app/performance/performance_policy.dart';
import 'shared/ui_v3/v3_brand_mark.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final decodedImages = PaintingBinding.instance.imageCache;
  decodedImages.maximumSize = 96;
  decodedImages.maximumSizeBytes = 48 * 1024 * 1024;
  const bootProbe = bool.fromEnvironment('HUAHUO_BOOT_PROBE');
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (<TargetPlatform>{
      TargetPlatform.android,
      TargetPlatform.iOS,
    }.contains(defaultTargetPlatform)) {
      unawaited(_warmBrandMark());
    }
  });
  runApp(_buildApp(bootProbe: bootProbe));
}

Future<void> _warmBrandMark() async {
  final assetPath = defaultTargetPlatform == TargetPlatform.android
      ? V3LaunchBrandLockup.androidAssetPath
      : V3BrandMark.assetPath;
  final stream = AssetImage(assetPath).resolve(ImageConfiguration.empty);
  final completion = Completer<void>();
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (_, _) {
      if (!completion.isCompleted) completion.complete();
    },
    onError: (Object error, StackTrace? stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace ?? StackTrace.current,
          library: 'infinite huahuo bootstrap',
          context: ErrorDescription('while pre-warming the launch brand mark'),
        ),
      );
      if (!completion.isCompleted) completion.complete();
    },
  );
  stream.addListener(listener);
  try {
    await completion.future.timeout(const Duration(seconds: 2));
  } on TimeoutException {
    // A native launch screen remains visible; never hold first paint forever.
  } finally {
    stream.removeListener(listener);
  }
}

Widget _buildApp({bool bootProbe = false}) {
  const performanceFlags = PerformanceFeatureFlags();
  final app = bootProbe
      ? const _LaunchProbe(child: AppRoot())
      : const AppRoot();
  return AppProviders(
    child: AppRuntimeActivation(
      child: AssetProjectionCacheScope(
        child: HomeWidgetSnapshotSync(
          enabled: performanceFlags.homeWidgetProjectionV2,
          child: app,
        ),
      ),
    ),
  );
}

class _LaunchProbe extends StatefulWidget {
  const _LaunchProbe({required this.child});

  final Widget child;

  @override
  State<_LaunchProbe> createState() => _LaunchProbeState();
}

class _LaunchProbeState extends State<_LaunchProbe> {
  Timer? _timer;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _timer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _visible = false);
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return widget.child;
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final surface = dark ? const Color(0xFF111817) : const Color(0xFFFFFFFF);
    final foreground = dark ? const Color(0xFFF3F7F5) : const Color(0xFF111827);
    return Stack(
      fit: StackFit.expand,
      textDirection: TextDirection.ltr,
      children: [
        widget.child,
        ColoredBox(
          color: surface,
          child: Center(
            child: Text(
              'HUAHUO_FLUTTER_BOOT',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: foreground,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
