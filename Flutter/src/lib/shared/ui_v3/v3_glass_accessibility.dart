import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

const _channelName = 'huahuoai/glass_accessibility';
const _getReduceTransparencyEnabled = 'getReduceTransparencyEnabled';
const _reduceTransparencyChanged = 'reduceTransparencyChanged';

/// Injectable native preference contract for V3 Liquid Glass accessibility.
abstract interface class GlassAccessibilityPort {
  Future<bool> getReduceTransparencyEnabled();

  Stream<bool> get reduceTransparencyChanges;

  void dispose();
}

/// iOS implementation of [GlassAccessibilityPort].
///
/// Other platforms, unavailable native handlers, and malformed replies all
/// resolve to `false` so glass rendering has a safe default.
final class MethodChannelGlassAccessibilityPort
    implements GlassAccessibilityPort {
  MethodChannelGlassAccessibilityPort({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName) {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  final MethodChannel _channel;
  final StreamController<bool> _changes = StreamController<bool>.broadcast();

  bool get _supportsNativeBridge =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Stream<bool> get reduceTransparencyChanges =>
      _supportsNativeBridge ? _changes.stream : const Stream<bool>.empty();

  @override
  Future<bool> getReduceTransparencyEnabled() async {
    if (!_supportsNativeBridge) return false;

    try {
      return await _channel.invokeMethod<bool>(_getReduceTransparencyEnabled) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method == _reduceTransparencyChanged && call.arguments is bool) {
      _changes.add(call.arguments! as bool);
    }
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    _changes.close();
  }
}

/// Observable state that keeps the last native Reduce Transparency setting.
final class GlassAccessibilityController extends ChangeNotifier {
  GlassAccessibilityController({GlassAccessibilityPort? port})
    : _port = port ?? MethodChannelGlassAccessibilityPort();

  final GlassAccessibilityPort _port;
  StreamSubscription<bool>? _changesSubscription;
  bool _initialized = false;
  bool _disposed = false;
  bool _reduceTransparency = false;

  bool get reduceTransparency => _reduceTransparency;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _changesSubscription = _port.reduceTransparencyChanges.listen(_setValue);
    _setValue(await _port.getReduceTransparencyEnabled());
  }

  void _setValue(bool value) {
    if (_disposed || _reduceTransparency == value) return;
    _reduceTransparency = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _changesSubscription?.cancel();
    _port.dispose();
    super.dispose();
  }
}

/// Bridges native transparency state and Flutter's Reduce Motion into the
/// Liquid Glass package's root [GlassAccessibilityScope].
class V3GlassAccessibilityScope extends StatefulWidget {
  const V3GlassAccessibilityScope({required this.child, this.port, super.key});

  final Widget child;
  final GlassAccessibilityPort? port;

  @override
  State<V3GlassAccessibilityScope> createState() =>
      _V3GlassAccessibilityScopeState();
}

class _V3GlassAccessibilityScopeState extends State<V3GlassAccessibilityScope> {
  late final GlassAccessibilityController _controller;

  @override
  void initState() {
    super.initState();
    _controller = GlassAccessibilityController(port: widget.port);
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        return GlassAccessibilityScope(
          reduceMotion: MediaQuery.disableAnimationsOf(context),
          reduceTransparency: _controller.reduceTransparency,
          child: child!,
        );
      },
    );
  }
}
