import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/navigation/app_route_observer.dart';
import '../../../recordings/application/recording_waveform_controller.dart';

class V3RecordingWaveformBuilder extends StatelessWidget {
  const V3RecordingWaveformBuilder({
    required this.source,
    required this.builder,
    super.key,
  });

  final RecordingWaveformController? source;
  final Widget Function(BuildContext context, List<double> samples) builder;

  @override
  Widget build(BuildContext context) {
    final waveform = source;
    if (waveform == null) {
      return RepaintBoundary(child: builder(context, const <double>[]));
    }
    return _LiveRecordingWaveform(source: waveform, builder: builder);
  }
}

class _LiveRecordingWaveform extends ConsumerStatefulWidget {
  const _LiveRecordingWaveform({required this.source, required this.builder});

  final RecordingWaveformController source;
  final Widget Function(BuildContext context, List<double> samples) builder;

  @override
  ConsumerState<_LiveRecordingWaveform> createState() =>
      _LiveRecordingWaveformState();
}

class _LiveRecordingWaveformState extends ConsumerState<_LiveRecordingWaveform>
    with AppActivityRouteAware<_LiveRecordingWaveform> {
  bool _listening = false;
  bool _tickerEnabled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _syncListening();
  }

  @override
  void didUpdateWidget(covariant _LiveRecordingWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source && _listening) {
      oldWidget.source.removeListener(_onSamples);
      _listening = false;
    }
    _syncListening();
  }

  @override
  void onActivityRouteBecameActive() {
    _syncListening();
    if (mounted) setState(() {});
  }

  @override
  void onActivityRouteBecameInactive() => _syncListening();

  void _syncListening() {
    final shouldListen = activityRouteCanRun && _tickerEnabled;
    if (_listening == shouldListen) return;
    _listening = shouldListen;
    if (shouldListen) {
      widget.source.addListener(_onSamples);
    } else {
      widget.source.removeListener(_onSamples);
    }
  }

  void _onSamples() {
    if (mounted && _listening) setState(() {});
  }

  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(child: widget.builder(context, widget.source.value));

  @override
  void dispose() {
    if (_listening) widget.source.removeListener(_onSamples);
    _listening = false;
    super.dispose();
  }
}
