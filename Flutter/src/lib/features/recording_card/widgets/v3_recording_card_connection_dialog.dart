import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/native/platform_permissions_port.dart';
import '../../../core/native/recording_card_native_port.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_liquid_glass.dart';
import '../application/recording_card_controller.dart';

const _connectionDialogEnterDuration = V3MotionTokens.pageTravel;
const _connectionDialogExitVisualDuration = V3MotionTokens.quick;

enum RecordingCardConnectionOutcome { connected, deferred, failed }

final class RecordingCardConnectionResult {
  const RecordingCardConnectionResult(
    this.outcome, {
    this.serialNumber,
    this.errorCode,
  });

  final RecordingCardConnectionOutcome outcome;
  final String? serialNumber;
  final String? errorCode;
}

Future<RecordingCardConnectionResult> showV3RecordingCardConnectionDialog(
  BuildContext context, {
  required RecordingCardController controller,
  bool requireSerialConfirmation = false,
  bool exitAfterFailure = false,
  PlatformPermissionsPort permissions =
      const MethodChannelPlatformPermissionsPort(),
}) async {
  return await _showV3RecordingCardDialog(
    context,
    controller: controller,
    requireSerialConfirmation: requireSerialConfirmation,
    exitAfterFailure: exitAfterFailure,
    permissions: permissions,
  );
}

Future<RecordingCardConnectionResult> _showV3RecordingCardDialog(
  BuildContext context, {
  required RecordingCardController controller,
  required bool requireSerialConfirmation,
  required bool exitAfterFailure,
  required PlatformPermissionsPort permissions,
}) async {
  if (controller.state.snapshot.deviceState.isOperationallyConnected) {
    return const RecordingCardConnectionResult(
      RecordingCardConnectionOutcome.deferred,
    );
  }
  final colors = HuahuoV3Theme.tokensOf(context);
  final disableAnimations = MediaQuery.disableAnimationsOf(context);
  return await showGeneralDialog<RecordingCardConnectionResult>(
        context: context,
        barrierDismissible: false,
        barrierLabel: '录音卡连接弹窗',
        barrierColor: colors.ink.withValues(alpha: .16),
        transitionDuration: disableAnimations
            ? Duration.zero
            : _connectionDialogEnterDuration,
        pageBuilder: (_, _, _) => SafeArea(
          child: _RecordingCardConnectionDialog(
            controller: controller,
            requireSerialConfirmation: requireSerialConfirmation,
            exitAfterFailure: exitAfterFailure,
            permissions: permissions,
          ),
        ),
        transitionBuilder: (context, animation, secondaryAnimation, child) {
          if (disableAnimations) {
            return KeyedSubtree(
              key: const ValueKey<String>(
                'recording-card-connection-transition',
              ),
              child: child,
            );
          }
          return AnimatedBuilder(
            animation: animation,
            child: child,
            builder: (context, child) {
              final value = _connectionDialogTransitionValue(animation);
              return FadeTransition(
                key: const ValueKey<String>('recording-card-connection-fade'),
                opacity: AlwaysStoppedAnimation<double>(value),
                child: KeyedSubtree(
                  key: const ValueKey<String>(
                    'recording-card-connection-transition',
                  ),
                  child: Transform.translate(
                    offset: Offset(0, 14 * (1 - value)),
                    child: Transform.scale(
                      scale: .92 + .08 * value,
                      alignment: Alignment.center,
                      child: child,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ) ??
      const RecordingCardConnectionResult(
        RecordingCardConnectionOutcome.deferred,
      );
}

double _connectionDialogTransitionValue(Animation<double> animation) {
  if (animation.status != AnimationStatus.reverse) {
    return Curves.easeOutCubic.transform(animation.value);
  }
  final exitVisualStart =
      1 -
      _connectionDialogExitVisualDuration.inMicroseconds /
          _connectionDialogEnterDuration.inMicroseconds;
  // showGeneralDialog has one route duration. Compress only the visual exit so
  // the panel settles before the route's barrier is removed.
  final normalized =
      ((animation.value - exitVisualStart) / (1 - exitVisualStart))
          .clamp(0.0, 1.0)
          .toDouble();
  return Curves.easeInCubic.transform(normalized);
}

class _RecordingCardConnectionDialog extends StatefulWidget {
  const _RecordingCardConnectionDialog({
    required this.controller,
    required this.requireSerialConfirmation,
    required this.exitAfterFailure,
    required this.permissions,
  });

  final RecordingCardController controller;
  final bool requireSerialConfirmation;
  final bool exitAfterFailure;
  final PlatformPermissionsPort permissions;

  @override
  State<_RecordingCardConnectionDialog> createState() =>
      _RecordingCardConnectionDialogState();
}

class _RecordingCardConnectionDialogState
    extends State<_RecordingCardConnectionDialog>
    with WidgetsBindingObserver {
  var _scanInFlight = false;
  var _ownsDiscoveryScan = false;
  var _connectionInFlight = false;
  var _automaticConnectionAttempted = false;
  var _automaticConnectionCheckInFlight = false;
  var _showSuccess = false;
  var _closing = false;
  var _bluetoothRecoveryInFlight = false;
  var _retryDiscoveryOnResume = false;
  String? _selectedFingerprint;
  String? _selectedDisplayName;
  RecordingCardDiscoveredDevice? _pendingSerialConfirmation;

  RecordingCardController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_hasCompletedConnection) {
        _completeConnection();
        return;
      }
      unawaited(_scanNearbyDevices());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerChanged);
    if (_ownsDiscoveryScan) {
      _ownsDiscoveryScan = false;
      unawaited(_controller.cancelDiscovery());
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_retryDiscoveryOnResume) return;
    _retryDiscoveryOnResume = false;
    unawaited(_scanNearbyDevices());
  }

  void _onControllerChanged() {
    if (!mounted || _closing) return;
    if (_hasCompletedConnection) {
      _completeConnection();
      return;
    }
    setState(() {});
  }

  bool get _hasCompletedConnection =>
      _controller.state.snapshot.deviceState.isOperationallyConnected;

  Future<void> _scanNearbyDevices() async {
    if (_scanInFlight || _connectionInFlight || _closing) return;
    setState(() {
      _scanInFlight = true;
      _automaticConnectionAttempted = false;
      _selectedFingerprint = null;
      _selectedDisplayName = null;
      _pendingSerialConfirmation = null;
    });
    _ownsDiscoveryScan = true;
    try {
      await _controller.scanDevices();
    } catch (_) {
      if (mounted && widget.exitAfterFailure) {
        _finish(
          const RecordingCardConnectionResult(
            RecordingCardConnectionOutcome.failed,
            errorCode: 'RECORDING_CARD_SCAN_FAILED',
          ),
        );
        return;
      }
    }
    _ownsDiscoveryScan = false;
    if (!mounted || _closing) return;
    if (_hasCompletedConnection) {
      _completeConnection();
      return;
    }
    setState(() => _scanInFlight = false);
    if (widget.exitAfterFailure &&
        (_controller.state.status == RecordingCardControllerStatus.error ||
            _visibleDevices().isEmpty)) {
      final error = _controller.state.lastErrorCode;
      _finish(
        RecordingCardConnectionResult(
          error == null
              ? RecordingCardConnectionOutcome.deferred
              : RecordingCardConnectionOutcome.failed,
          errorCode: error,
        ),
      );
      return;
    }
    unawaited(_tryAutomaticConnection());
  }

  Future<void> _recoverBluetooth(String errorCode) async {
    if (_bluetoothRecoveryInFlight || _closing) return;
    switch (_bluetoothRecoveryKind(errorCode)) {
      case _BluetoothRecoveryKind.activate:
        return _requestBluetoothActivation();
      case _BluetoothRecoveryKind.appSettings:
        return _openAppPermissionSettings();
      case _BluetoothRecoveryKind.locationSettings:
        return _openLocationSettings();
      case null:
        return;
    }
  }

  Future<void> _requestBluetoothActivation() async {
    setState(() => _bluetoothRecoveryInFlight = true);
    final result = await widget.permissions.requestBluetoothActivation();
    if (!mounted || _closing) return;
    setState(() => _bluetoothRecoveryInFlight = false);
    if (result.ok && result.value == BluetoothActivationResult.enabled) {
      await _scanNearbyDevices();
      return;
    }
    if (result.ok && result.value == BluetoothActivationResult.cancelled) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('蓝牙未打开，暂时无法搜索录音卡')));
      return;
    }
    await _openAppPermissionSettings();
  }

  Future<void> _openAppPermissionSettings() async {
    if (!mounted || _closing) return;
    setState(() {
      _bluetoothRecoveryInFlight = true;
      _retryDiscoveryOnResume = true;
    });
    final opened = await widget.permissions.openAppSettings(
      PlatformPermissionKind.bluetooth,
      impactAcknowledged: true,
    );
    if (!mounted || _closing) return;
    setState(() => _bluetoothRecoveryInFlight = false);
    if (opened.ok && opened.value?.opened == true) return;
    _retryDiscoveryOnResume = false;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开应用设置，请手动授权蓝牙')));
  }

  Future<void> _openLocationSettings() async {
    if (!mounted || _closing) return;
    setState(() {
      _bluetoothRecoveryInFlight = true;
      _retryDiscoveryOnResume = true;
    });
    final permissions = widget.permissions;
    final opened = permissions is BluetoothSettingsRecoveryPort
        ? await (permissions as BluetoothSettingsRecoveryPort)
              .openBluetoothSettings(BluetoothSettingsTarget.locationServices)
        : null;
    if (!mounted || _closing) return;
    setState(() => _bluetoothRecoveryInFlight = false);
    if (opened?.ok == true && opened?.value?.opened == true) return;
    _retryDiscoveryOnResume = false;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开定位设置，请手动开启系统定位服务')));
  }

  Future<void> _tryAutomaticConnection() async {
    if (widget.requireSerialConfirmation) return;
    if (_automaticConnectionAttempted ||
        _automaticConnectionCheckInFlight ||
        _connectionInFlight ||
        _controller.state.status != RecordingCardControllerStatus.idle) {
      return;
    }
    _automaticConnectionCheckInFlight = true;
    final matchingDevices = await _controller
        .cachedAuthorizedDiscoveredDevices();
    _automaticConnectionCheckInFlight = false;
    if (!mounted || _closing || _connectionInFlight) return;
    if (matchingDevices.length != 1) return;
    _automaticConnectionAttempted = true;
    unawaited(_connect(matchingDevices.single));
  }

  void _selectDevice(RecordingCardDiscoveredDevice device) {
    if (_connectionInFlight || _closing || device.isConnectable == false) {
      return;
    }
    if (widget.requireSerialConfirmation) {
      setState(() {
        _selectedFingerprint = device.safeDeviceFingerprint;
        _selectedDisplayName = device.displayName;
        _pendingSerialConfirmation = device;
      });
      return;
    }
    unawaited(_connect(device));
  }

  void _returnToDeviceList() {
    setState(() {
      _selectedFingerprint = null;
      _selectedDisplayName = null;
      _pendingSerialConfirmation = null;
    });
  }

  void _confirmSerialNumber() {
    final device = _pendingSerialConfirmation;
    if (device == null || !_hasReadableSerialNumber(device)) return;
    unawaited(_connect(device));
  }

  Future<void> _connect(RecordingCardDiscoveredDevice device) async {
    if (_connectionInFlight || _closing || device.isConnectable == false) {
      return;
    }
    setState(() {
      _connectionInFlight = true;
      _selectedFingerprint = device.safeDeviceFingerprint;
      _selectedDisplayName = device.displayName;
      _pendingSerialConfirmation = null;
    });
    try {
      await _controller.connectDiscoveredDevice(device);
    } catch (_) {
      if (mounted && !_closing) {
        setState(() => _connectionInFlight = false);
        if (widget.exitAfterFailure) {
          _finish(
            const RecordingCardConnectionResult(
              RecordingCardConnectionOutcome.failed,
              errorCode: 'RECORDING_CARD_CONNECT_FAILED',
            ),
          );
        }
      }
      return;
    }
    if (!mounted || _closing) return;
    if (_hasCompletedConnection) {
      _completeConnection();
      return;
    }
    setState(() => _connectionInFlight = false);
    if (widget.exitAfterFailure) {
      _finish(
        RecordingCardConnectionResult(
          RecordingCardConnectionOutcome.failed,
          errorCode:
              _controller.state.lastErrorCode ??
              'RECORDING_CARD_CONNECT_INCOMPLETE',
        ),
      );
    }
  }

  void _finish(RecordingCardConnectionResult result) {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).pop(result);
  }

  void _completeConnection() {
    if (_closing || !mounted) return;
    if (widget.requireSerialConfirmation && !_connectionInFlight) {
      _finish(
        const RecordingCardConnectionResult(
          RecordingCardConnectionOutcome.deferred,
        ),
      );
      return;
    }
    final result = RecordingCardConnectionResult(
      RecordingCardConnectionOutcome.connected,
      serialNumber: _controller.state.snapshot.deviceState.serialNumber,
    );
    setState(() {
      _showSuccess = true;
      _closing = true;
    });
    Future<void>.delayed(V3FeedbackTimingTokens.connectionSuccess, () {
      if (!mounted) return;
      Navigator.of(context).pop(result);
    });
  }

  List<RecordingCardDiscoveredDevice> _visibleDevices() {
    final rememberedFingerprints = _controller.recentlyConnectedDevices
        .map((entry) => entry.safeDeviceFingerprint)
        .toSet();
    final devices = List<RecordingCardDiscoveredDevice>.of(
      _controller.state.snapshot.discoveredDevices,
    );
    devices.sort((left, right) {
      final leftRemembered = rememberedFingerprints.contains(
        left.safeDeviceFingerprint,
      );
      final rightRemembered = rememberedFingerprints.contains(
        right.safeDeviceFingerprint,
      );
      if (leftRemembered != rightRemembered) {
        return leftRemembered ? -1 : 1;
      }
      final leftConnectable = left.isConnectable != false;
      final rightConnectable = right.isConnectable != false;
      if (leftConnectable != rightConnectable) {
        return leftConnectable ? -1 : 1;
      }
      final signalOrder = (right.rssi ?? -128).compareTo(left.rssi ?? -128);
      if (signalOrder != 0) return signalOrder;
      return left.displayName.compareTo(right.displayName);
    });
    return devices;
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final state = _controller.state;
    final discoveredDevices = _visibleDevices();
    final duplicateDisplayNames = <String>{
      for (final device in discoveredDevices)
        if (discoveredDevices
                .where(
                  (candidate) =>
                      candidate.displayName.trim().toLowerCase() ==
                      device.displayName.trim().toLowerCase(),
                )
                .length >
            1)
          device.displayName.trim().toLowerCase(),
    };
    final rememberedFingerprints = _controller.recentlyConnectedDevices
        .map((entry) => entry.safeDeviceFingerprint)
        .toSet();
    final scanning =
        _scanInFlight || state.status == RecordingCardControllerStatus.scanning;
    final authorizing =
        state.status == RecordingCardControllerStatus.authorizing;
    final connecting =
        _connectionInFlight ||
        state.status == RecordingCardControllerStatus.connecting ||
        authorizing;
    final confirmationDevice = _pendingSerialConfirmation;
    final confirmingSerial =
        confirmationDevice != null && !connecting && !_showSuccess;
    final devices = connecting && _selectedFingerprint != null
        ? discoveredDevices
              .where(
                (device) =>
                    device.safeDeviceFingerprint == _selectedFingerprint,
              )
              .toList(growable: false)
        : discoveredDevices;
    final errorCode = state.status == RecordingCardControllerStatus.error
        ? state.lastErrorCode
        : null;
    final bluetoothUnsupported =
        errorCode == 'RECORDING_CARD_BLUETOOTH_UNSUPPORTED';
    final recoveryKind = _bluetoothRecoveryKind(errorCode);
    final title = _showSuccess
        ? '录音卡已连接'
        : authorizing
        ? '正在验证录音卡'
        : connecting
        ? '正在连接录音卡'
        : confirmingSerial
        ? '核对 SN 码'
        : scanning
        ? '正在搜索录音卡'
        : bluetoothUnsupported
        ? '当前设备不支持蓝牙连接'
        : '选择录音卡';
    final subtitle = _showSuccess
        ? '${_selectedDisplayName ?? state.snapshot.deviceState.displayName ?? '录音卡'} 已准备就绪'
        : authorizing
        ? '正在核验 SN 和账号归属'
        : connecting
        ? '正在连接 ${_selectedDisplayName ?? '所选录音卡'}'
        : confirmingSerial
        ? '请核对机身背面 SN，确认无误后再连接'
        : errorCode != null
        ? '连接未完成，请查看下方提示。'
        : scanning
        ? '正在查找附近已开启的录音卡'
        : devices.isEmpty
        ? '未发现附近的录音卡'
        : '请选择要连接的录音卡';

    const panelHeight = 532.0;
    final media = MediaQuery.of(context);
    final compactHeight = media.size.height - media.viewPadding.vertical < 400;
    final topInset = compactHeight ? 12.0 : 64.0;
    final bottomInset = compactHeight ? 12.0 : 24.0;
    final availableHeight =
        media.size.height - media.viewPadding.vertical - topInset - bottomInset;
    final effectiveHeight = availableHeight.clamp(0.0, panelHeight).toDouble();

    return Dialog(
      key: const ValueKey<String>('recording-card-connection-dialog'),
      backgroundColor: Colors.transparent,
      elevation: 0,
      alignment: Alignment.topCenter,
      insetPadding: EdgeInsets.fromLTRB(20, topInset, 20, bottomInset),
      child: SizedBox(
        key: const ValueKey<String>('recording-card-connection-panel'),
        width: 362,
        height: effectiveHeight,
        child: V3LiquidGlassSurface(
          borderRadius: 28,
          child: Material(
            type: MaterialType.transparency,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
              child: Column(
                mainAxisSize: MainAxisSize.max,
                children: [
                  _ConnectionHeader(
                    colors: colors,
                    scanning: scanning,
                    connecting: connecting,
                    connected: _showSuccess,
                    title: title,
                    subtitle: subtitle,
                    compact: compactHeight,
                  ),
                  const SizedBox(height: 16),
                  Divider(height: 1, color: colors.line),
                  const SizedBox(height: 8),
                  if (errorCode != null && devices.isNotEmpty) ...[
                    _ConnectionErrorStrip(
                      colors: colors,
                      message: _connectionFailureMessage(errorCode),
                      recoveryLabel: _bluetoothRecoveryLabel(recoveryKind),
                      busy: _bluetoothRecoveryInFlight,
                      onRecover: () => _recoverBluetooth(errorCode),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Expanded(
                    child: confirmingSerial
                        ? _SerialNumberConfirmation(device: confirmationDevice)
                        : devices.isEmpty
                        ? _EmptyNearbyDevices(
                            colors: colors,
                            scanning: scanning,
                            errorCode: errorCode,
                            recoveryLabel: _bluetoothRecoveryLabel(
                              recoveryKind,
                            ),
                            recoveryIcon: _bluetoothRecoveryIcon(recoveryKind),
                            recoveryBusy: _bluetoothRecoveryInFlight,
                            onRecoverBluetooth: errorCode == null
                                ? null
                                : () => _recoverBluetooth(errorCode),
                          )
                        : ListView.separated(
                            key: const ValueKey(
                              'recording-card-connection-device-list',
                            ),
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: devices.length,
                            separatorBuilder: (_, _) => Divider(
                              height: 1,
                              color: colors.line.withValues(alpha: .78),
                            ),
                            itemBuilder: (context, index) {
                              final device = devices[index];
                              return _NearbyDeviceRow(
                                key: ValueKey(
                                  'recording-card-nearby-device-${device.safeDeviceFingerprint}',
                                ),
                                device: device,
                                remembered: rememberedFingerprints.contains(
                                  device.safeDeviceFingerprint,
                                ),
                                selected:
                                    _selectedFingerprint ==
                                    device.safeDeviceFingerprint,
                                connectionInFlight: connecting,
                                showDeviceCode: duplicateDisplayNames.contains(
                                  device.displayName.trim().toLowerCase(),
                                ),
                                onPressed: () => _selectDevice(device),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    key: const ValueKey('recording-card-connection-actions'),
                    children: [
                      if (!bluetoothUnsupported) ...[
                        Expanded(
                          child: V3OutlineButton(
                            key: const ValueKey(
                              'recording-card-connection-cancel',
                            ),
                            label: widget.exitAfterFailure
                                ? '稍后连接'
                                : confirmingSerial
                                ? '返回'
                                : '取消',
                            enabled:
                                !_showSuccess &&
                                (widget.exitAfterFailure || !connecting),
                            onPressed:
                                confirmingSerial && !widget.exitAfterFailure
                                ? _returnToDeviceList
                                : () => _finish(
                                    const RecordingCardConnectionResult(
                                      RecordingCardConnectionOutcome.deferred,
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(width: 14),
                      ],
                      Expanded(
                        child: V3PrimaryButton(
                          key: const ValueKey(
                            'recording-card-connection-rescan',
                          ),
                          label: bluetoothUnsupported
                              ? '关闭'
                              : confirmingSerial
                              ? 'SN 一致，连接'
                              : '重新搜索',
                          enabled: bluetoothUnsupported
                              ? true
                              : confirmingSerial
                              ? _hasReadableSerialNumber(confirmationDevice)
                              : !scanning && !connecting && !_showSuccess,
                          onPressed: bluetoothUnsupported
                              ? () => _finish(
                                  const RecordingCardConnectionResult(
                                    RecordingCardConnectionOutcome.deferred,
                                  ),
                                )
                              : confirmingSerial
                              ? _confirmSerialNumber
                              : () => unawaited(_scanNearbyDevices()),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectionHeader extends StatelessWidget {
  const _ConnectionHeader({
    required this.colors,
    required this.scanning,
    required this.connecting,
    required this.connected,
    required this.title,
    required this.subtitle,
    required this.compact,
  });

  final HuahuoV3ThemeTokens colors;
  final bool scanning;
  final bool connecting;
  final bool connected;
  final String title;
  final String subtitle;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final accent = connected
        ? colors.success
        : connecting || scanning
        ? colors.primary
        : colors.accent;
    if (compact) {
      return Row(
        children: [
          SizedBox(
            width: 56,
            height: 52,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                ClipOval(
                  child: ColoredBox(
                    color: accent.withValues(alpha: .1),
                    child: SizedBox.square(
                      dimension: 48,
                      child: Padding(
                        padding: const EdgeInsets.all(7),
                        child: Image.asset(
                          'assets/images/recording_card_device.png',
                          fit: BoxFit.contain,
                          semanticLabel: '无限花火录音卡',
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colors.surface,
                      border: Border.all(color: colors.line),
                    ),
                    child: SizedBox.square(
                      dimension: 22,
                      child: Center(
                        child: connected
                            ? Icon(
                                Icons.check_rounded,
                                size: 15,
                                color: colors.success,
                              )
                            : scanning || connecting
                            ? SizedBox.square(
                                dimension: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.8,
                                  color: accent,
                                ),
                              )
                            : Icon(
                                Icons.bluetooth_searching_rounded,
                                size: 14,
                                color: accent,
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.ink,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.muted,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return Column(
      children: [
        SizedBox(
          width: 106,
          height: 94,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: accent.withValues(alpha: .18)),
                ),
              ),
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(alpha: .10),
                ),
              ),
              ClipOval(
                child: ColoredBox(
                  color: colors.surface.withValues(alpha: .92),
                  child: SizedBox.square(
                    dimension: 60,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Image.asset(
                        'assets/images/recording_card_device.png',
                        fit: BoxFit.contain,
                        semanticLabel: '无限花火录音卡',
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 3,
                bottom: 5,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.surface,
                    border: Border.all(color: colors.line),
                  ),
                  child: SizedBox.square(
                    dimension: 28,
                    child: Center(
                      child: connected
                          ? Icon(
                              Icons.check_rounded,
                              size: 18,
                              color: colors.success,
                            )
                          : scanning || connecting
                          ? SizedBox.square(
                              dimension: 15,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: accent,
                              ),
                            )
                          : Icon(
                              Icons.bluetooth_searching_rounded,
                              size: 17,
                              color: accent,
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 5),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colors.ink,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: colors.muted, fontSize: 13, height: 1.35),
        ),
      ],
    );
  }
}

class _SerialNumberConfirmation extends StatelessWidget {
  const _SerialNumberConfirmation({required this.device});

  final RecordingCardDiscoveredDevice device;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final serial = _readableSerialNumber(device);
    return ListView(
      key: const ValueKey<String>('recording-card-serial-confirmation'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        _SerialConfirmationRow(
          icon: Icons.graphic_eq_rounded,
          title: device.displayName,
          subtitle: serial == null
              ? '未读取到设备 SN'
              : '机身末 6 位：${_serialTail(serial)}',
          trailing: '待核对',
        ),
        Divider(height: 1, color: colors.line.withValues(alpha: .78)),
        _SerialConfirmationRow(
          icon: Icons.bluetooth_rounded,
          title: '完整 SN 码',
          subtitle: serial ?? '请重新搜索后再试',
          trailingIcon: serial == null
              ? Icons.error_outline_rounded
              : Icons.verified_outlined,
          danger: serial == null,
        ),
      ],
    );
  }
}

class _SerialConfirmationRow extends StatelessWidget {
  const _SerialConfirmationRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.trailingIcon,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? trailing;
  final IconData? trailingIcon;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final foreground = danger ? colors.danger : colors.muted;
    return SizedBox(
      height: 78,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: foreground.withValues(alpha: .10),
            ),
            child: Icon(icon, color: foreground, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: foreground, fontSize: 12.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (trailing != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                trailing!,
                style: TextStyle(color: colors.muted, fontSize: 12),
              ),
            )
          else if (trailingIcon != null)
            Icon(trailingIcon, color: foreground, size: 20),
        ],
      ),
    );
  }
}

class _EmptyNearbyDevices extends StatelessWidget {
  const _EmptyNearbyDevices({
    required this.colors,
    required this.scanning,
    required this.errorCode,
    required this.recoveryLabel,
    required this.recoveryIcon,
    required this.recoveryBusy,
    required this.onRecoverBluetooth,
  });

  final HuahuoV3ThemeTokens colors;
  final bool scanning;
  final String? errorCode;
  final String? recoveryLabel;
  final IconData? recoveryIcon;
  final bool recoveryBusy;
  final VoidCallback? onRecoverBluetooth;

  @override
  Widget build(BuildContext context) {
    final message = errorCode != null
        ? _connectionFailureMessage(errorCode!)
        : scanning
        ? '正在搜索附近设备...'
        : '请确认录音卡已开启并靠近手机后重新搜索。';
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        key: const ValueKey('recording-card-empty-state-scroll'),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    errorCode == null
                        ? Icons.bluetooth_searching_rounded
                        : Icons.bluetooth_disabled_rounded,
                    color: errorCode == null ? colors.muted : colors.danger,
                    size: 28,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.muted, height: 1.4),
                  ),
                  if (recoveryLabel != null && onRecoverBluetooth != null) ...[
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      key: const ValueKey<String>(
                        'recording-card-bluetooth-recovery',
                      ),
                      onPressed: recoveryBusy ? null : onRecoverBluetooth,
                      icon: recoveryBusy
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(recoveryIcon, size: 18),
                      label: Text(recoveryLabel!),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectionErrorStrip extends StatelessWidget {
  const _ConnectionErrorStrip({
    required this.colors,
    required this.message,
    required this.recoveryLabel,
    required this.busy,
    required this.onRecover,
  });

  final HuahuoV3ThemeTokens colors;
  final String message;
  final String? recoveryLabel;
  final bool busy;
  final VoidCallback onRecover;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
      decoration: BoxDecoration(
        color: colors.danger.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 18, color: colors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: colors.danger, fontSize: 12.5),
            ),
          ),
          if (recoveryLabel != null)
            TextButton(
              onPressed: busy ? null : onRecover,
              child: Text(busy ? '处理中' : recoveryLabel!),
            ),
        ],
      ),
    );
  }
}

class _NearbyDeviceRow extends StatelessWidget {
  const _NearbyDeviceRow({
    required this.device,
    required this.remembered,
    required this.selected,
    required this.connectionInFlight,
    required this.showDeviceCode,
    required this.onPressed,
    super.key,
  });

  final RecordingCardDiscoveredDevice device;
  final bool remembered;
  final bool selected;
  final bool connectionInFlight;
  final bool showDeviceCode;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final connectable = device.isConnectable != false;
    final enabled = connectable && !connectionInFlight;
    final status = selected && connectionInFlight
        ? '正在连接'
        : !connectable
        ? '暂不可连接'
        : remembered
        ? '上次连接'
        : _signalLabel(device.rssi);
    final detail = showDeviceCode
        ? '设备识别码 ${_deviceShortCode(device.safeDeviceFingerprint)} · $status'
        : status;
    final serialNumber = device.serialNumber;
    return Semantics(
      button: enabled,
      enabled: enabled,
      label: [
        device.displayName,
        if (serialNumber != null) 'SN $serialNumber',
        detail,
      ].join('，'),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: enabled ? onPressed : null,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (selected ? colors.primary : colors.accent)
                        .withValues(alpha: .11),
                  ),
                  child: Icon(
                    Icons.graphic_eq_rounded,
                    color: selected ? colors.primary : colors.accent,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: connectable ? colors.ink : colors.muted,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0,
                        ),
                      ),
                      if (serialNumber != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          'SN：$serialNumber',
                          key: ValueKey(
                            'recording-card-serial-${device.safeDeviceFingerprint}',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: connectable ? colors.muted : colors.danger,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0,
                          ),
                        ),
                      ],
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          if (device.rssi != null && connectable) ...[
                            Icon(
                              Icons.network_cell_rounded,
                              size: 14,
                              color: colors.muted,
                            ),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Text(
                              detail,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: selected
                                    ? colors.primary
                                    : connectable
                                    ? colors.muted
                                    : colors.danger,
                                fontSize: 12.5,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                letterSpacing: 0,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (selected && connectionInFlight)
                  SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.primary,
                    ),
                  )
                else if (remembered)
                  Icon(Icons.bolt_rounded, color: colors.primary, size: 20)
                else
                  Icon(
                    Icons.chevron_right_rounded,
                    color: enabled ? colors.muted : colors.line,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

bool _hasReadableSerialNumber(RecordingCardDiscoveredDevice device) =>
    _readableSerialNumber(device) != null;

String? _readableSerialNumber(RecordingCardDiscoveredDevice device) {
  final serial = device.serialNumber?.trim();
  return serial == null || serial.isEmpty ? null : serial;
}

String _serialTail(String serial) =>
    serial.length <= 6 ? serial : serial.substring(serial.length - 6);

String _signalLabel(int? rssi) {
  if (rssi == null) return '可连接';
  if (rssi >= -58) return '信号强';
  if (rssi >= -74) return '信号良好';
  return '信号较弱';
}

String _deviceShortCode(String safeDeviceFingerprint) {
  final compact = safeDeviceFingerprint.replaceAll(RegExp('[^A-Za-z0-9]'), '');
  final suffix = compact.length <= 6
      ? compact
      : compact.substring(compact.length - 6);
  return suffix.toUpperCase();
}

enum _BluetoothRecoveryKind { activate, appSettings, locationSettings }

_BluetoothRecoveryKind? _bluetoothRecoveryKind(String? code) {
  return switch (code) {
    'RECORDING_CARD_BLUETOOTH_POWERED_OFF' => _BluetoothRecoveryKind.activate,
    'RECORDING_CARD_BLUETOOTH_PERMISSION_REQUIRED' ||
    'RECORDING_CARD_BLUETOOTH_UNAUTHORIZED' =>
      _BluetoothRecoveryKind.appSettings,
    'RECORDING_CARD_LOCATION_SERVICES_DISABLED' =>
      _BluetoothRecoveryKind.locationSettings,
    _ => null,
  };
}

String? _bluetoothRecoveryLabel(_BluetoothRecoveryKind? kind) {
  return switch (kind) {
    _BluetoothRecoveryKind.activate => '打开蓝牙',
    _BluetoothRecoveryKind.appSettings => '授权蓝牙',
    _BluetoothRecoveryKind.locationSettings => '开启定位服务',
    null => null,
  };
}

IconData? _bluetoothRecoveryIcon(_BluetoothRecoveryKind? kind) {
  return switch (kind) {
    _BluetoothRecoveryKind.activate => Icons.bluetooth_rounded,
    _BluetoothRecoveryKind.appSettings => Icons.settings_rounded,
    _BluetoothRecoveryKind.locationSettings => Icons.location_on_rounded,
    null => null,
  };
}

String _connectionFailureMessage(String code) {
  return switch (code) {
    'RECORDING_CARD_BLUETOOTH_POWERED_OFF' => '请先在系统设置中打开手机蓝牙。',
    'RECORDING_CARD_BLUETOOTH_PERMISSION_REQUIRED' ||
    'RECORDING_CARD_BLUETOOTH_UNAUTHORIZED' => '请允许应用使用蓝牙后重新搜索。',
    'RECORDING_CARD_LOCATION_SERVICES_DISABLED' =>
      'Android 7～11 需要开启系统定位服务才能搜索录音卡，请开启后重新搜索。',
    'RECORDING_CARD_BLUETOOTH_UNSUPPORTED' => '当前设备不支持低功耗蓝牙（BLE），无法搜索或连接录音卡。',
    'RECORDING_CARD_SCAN_THROTTLED' => '搜索过于频繁，请稍候片刻再重新搜索。',
    'RECORDING_CARD_SCAN_FAILED' => '蓝牙搜索启动失败，请关闭后重新打开蓝牙再试。',
    'NATIVE_RECORDING_CARD_DRIVER_UNAVAILABLE' => '当前设备暂不支持录音卡连接。',
    'RECORDING_CARD_DISCOVERED_DEVICE_UNAVAILABLE' => '该录音卡暂时不可连接，请重新搜索。',
    'RECORDING_CARD_CONNECT_FAILED' => '蓝牙链路未能建立，请确认录音卡已开启并靠近手机后重试。',
    'RECORDING_CARD_DISCONNECTED' ||
    'RECORDING_CARD_NOT_CONNECTED' => '连接过程中蓝牙已断开，请确认录音卡状态后重新搜索。',
    'RECORDING_CARD_SERVICE_DISCOVERY_FAILED' ||
    'RECORDING_CARD_SERVICE_MISSING' ||
    'RECORDING_CARD_CHARACTERISTIC_DISCOVERY_FAILED' ||
    'RECORDING_CARD_PROFILE_INCOMPLETE' ||
    'RECORDING_CARD_NOTIFICATION_FAILED' ||
    'RECORDING_CARD_MTU_NEGOTIATION_FAILED' ||
    'RECORDING_CARD_MTU_NEGOTIATION_TIMEOUT' => '已连接蓝牙，但录音卡服务初始化失败，请重启录音卡后重试。',
    'RECORDING_CARD_SETUP_TIMEOUT' => '录音卡连接初始化超时，请重新连接。',
    'RECORDING_CARD_CONNECT_BUSY' ||
    'RECORDING_CARD_FORCE_SCAN_BUSY' => '当前录音卡仍在使用，请先结束录音或传输，再断开后重试。',
    'RECORDING_CARD_HANDSHAKE_FAILED' => '已连接蓝牙，但录音卡安全握手未完成，请重启后重试。',
    'RECORDING_CARD_ADVERTISEMENT_SN_INVALID' => '未能识别录音卡广播中的 SN，请重启录音卡后重新搜索。',
    'RECORDING_CARD_ADVERTISEMENT_SN_MISMATCH' =>
      '连接设备的 SN 与广播不一致，已停止连接，请重新搜索。',
    'RECORDING_CARD_BINDING_INFO_MALFORMED' => '录音卡返回的配对信息格式异常，无法完成握手，请重新连接。',
    'RECORDING_CARD_BINDING_INFO_TIMEOUT' => '录音卡未在配对时限内返回绑定信息，请靠近录音卡后重新连接。',
    'RECORDING_CARD_BINDING_WINDOW_EXPIRED' => '未能在录音卡要求的 5 秒内发送配对指令，请重新连接。',
    'RECORDING_CARD_BINDING_REJECTED' => '录音卡拒绝了本次配对，设备未提供具体原因；这不代表已绑定其他手机。',
    'RECORDING_CARD_BINDING_ACK_MALFORMED' => '录音卡返回的配对结果格式异常，尚不能确认配对成功，请重新连接。',
    'RECORDING_CARD_BINDING_ACK_TIMEOUT' => '配对指令已发送，但未收到录音卡确认，请重新连接。',
    'RECORDING_CARD_COMMAND_TIMEOUT' => '录音卡未及时响应连接指令，请靠近录音卡后重试。',
    'RECORDING_CARD_WRITE_FAILED' => '蓝牙未能发送连接指令，请重新连接。',
    'RECORDING_CARD_COMMAND_IN_PROGRESS' => '录音卡仍有连接指令正在处理，请稍后重试。',
    'RECORDING_CARD_BINDING_CONFLICT' => '录音卡配对未完成，当前错误信息不足以判断绑定归属，请重新连接。',
    'RECORDING_CARD_NOT_REGISTERED' => '云端没有登记此录音卡，不会进行连接，请联系售后核对 SN。',
    'RECORDING_CARD_ALREADY_BOUND' => '该录音卡已绑定其他账号，不会进行连接。',
    'RECORDING_CARD_ACCOUNT_LIMIT_REACHED' => '当前账号已绑定其他录音卡，请先解除原绑定。',
    'RECORDING_CARD_CLOUD_BINDING_AUTH_REQUIRED' => '登录状态已失效，请重新登录后连接录音卡。',
    'RECORDING_CARD_CLOUD_BINDING_REQUEST_FAILED' ||
    'RECORDING_CARD_BIND_FAILED' => '云端校验暂时失败，不会进行连接，请稍后重试。',
    _ => '连接未完成，请重新搜索或选择其他录音卡。',
  };
}
