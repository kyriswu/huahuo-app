import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_operation_machine.dart';

void main() {
  group('RecordingCardOperationMachine', () {
    test(
      'keeps one owner and distinguishes user block from automatic wait',
      () {
        final machine = RecordingCardOperationMachine();
        final transfer = machine.begin(
          kind: RecordingCardOperationKind.bluetoothTransfer,
          origin: RecordingCardOperationOrigin.automatic,
          connectionRevision: 7,
        );

        expect(transfer.admitted, isTrue);
        final user = machine.begin(
          kind: RecordingCardOperationKind.wifiTransfer,
          origin: RecordingCardOperationOrigin.user,
          connectionRevision: 7,
        );
        expect(user.admitted, isFalse);
        expect(user.failureCode, recordingCardOperationBusyCode);
        expect(
          machine.state.kind,
          RecordingCardOperationKind.bluetoothTransfer,
        );
        expect(
          machine.state.blockedKind,
          RecordingCardOperationKind.wifiTransfer,
        );

        final automatic = machine.begin(
          kind: RecordingCardOperationKind.directoryRefresh,
          origin: RecordingCardOperationOrigin.automatic,
          connectionRevision: 7,
        );
        expect(automatic.deferred, isTrue);
        expect(
          machine.state.kind,
          RecordingCardOperationKind.bluetoothTransfer,
        );
        expect(
          machine.state.blockedKind,
          RecordingCardOperationKind.directoryRefresh,
        );
      },
    );

    test('cancelled is terminal and cancellation rejection retains owner', () {
      final machine = RecordingCardOperationMachine();
      final lease = machine
          .begin(
            kind: RecordingCardOperationKind.bluetoothTransfer,
            origin: RecordingCardOperationOrigin.user,
            connectionRevision: 4,
          )
          .lease!;
      expect(machine.requestCancellation(lease), isTrue);
      expect(machine.rejectCancellation(lease), isTrue);
      expect(machine.state.phase, RecordingCardOperationPhase.running);
      expect(machine.owns(lease), isTrue);
      expect(machine.requestCancellation(lease), isTrue);
      expect(machine.cancel(lease), isTrue);
      expect(machine.state.phase, RecordingCardOperationPhase.cancelled);
      expect(machine.owns(lease), isFalse);
      expect(machine.succeed(lease), isFalse);
      expect(machine.rejectCancellation(lease), isFalse);
    });

    test('verified completion wins over late cancellation', () {
      final machine = RecordingCardOperationMachine();
      final lease = machine
          .begin(
            kind: RecordingCardOperationKind.bluetoothTransfer,
            origin: RecordingCardOperationOrigin.user,
            connectionRevision: 4,
          )
          .lease!;
      machine.requestCancellation(lease);
      expect(machine.succeed(lease), isTrue);
      expect(machine.cancel(lease), isFalse);
      expect(machine.state.phase, RecordingCardOperationPhase.succeeded);
    });

    test('latches terminal result and rejects stale completion', () {
      final machine = RecordingCardOperationMachine();
      final first = machine.begin(
        kind: RecordingCardOperationKind.directoryRefresh,
        origin: RecordingCardOperationOrigin.automatic,
        connectionRevision: 3,
      );
      expect(machine.fail(first.lease!, 'RECORDING_CARD_SCAN_FAILED'), isTrue);
      expect(machine.state.phase, RecordingCardOperationPhase.failed);
      expect(machine.state.errorCode, 'RECORDING_CARD_SCAN_FAILED');

      final second = machine.begin(
        kind: RecordingCardOperationKind.recordingControl,
        origin: RecordingCardOperationOrigin.user,
        connectionRevision: 3,
      );
      expect(second.admitted, isTrue);
      expect(machine.succeed(first.lease!), isFalse);
      expect(machine.state.kind, RecordingCardOperationKind.recordingControl);
      expect(machine.state.phase, RecordingCardOperationPhase.running);
    });

    test('cancellation and connection replacement retain exact ownership', () {
      final machine = RecordingCardOperationMachine();
      final transfer = machine.begin(
        kind: RecordingCardOperationKind.wifiTransfer,
        origin: RecordingCardOperationOrigin.user,
        connectionRevision: 11,
      );
      expect(machine.requestCancellation(transfer.lease!), isTrue);
      expect(machine.state.phase, RecordingCardOperationPhase.cancelling);
      expect(machine.interruptForConnectionRevision(12), isTrue);
      expect(machine.state.phase, RecordingCardOperationPhase.interrupted);
      expect(machine.state.errorCode, recordingCardOperationSessionChangedCode);
      expect(machine.succeed(transfer.lease!), isFalse);
    });

    test('lifecycle supersession invalidates the replaced generation', () {
      final machine = RecordingCardOperationMachine();
      final refresh = machine.begin(
        kind: RecordingCardOperationKind.directoryRefresh,
        origin: RecordingCardOperationOrigin.automatic,
        connectionRevision: 5,
      );

      final disconnect = machine.supersede(
        kind: RecordingCardOperationKind.disconnect,
        origin: RecordingCardOperationOrigin.user,
        connectionRevision: 5,
      );

      expect(disconnect.admitted, isTrue);
      expect(
        disconnect.lease!.generation,
        greaterThan(refresh.lease!.generation),
      );
      expect(machine.succeed(refresh.lease!), isFalse);
      expect(machine.state.kind, RecordingCardOperationKind.disconnect);
      expect(machine.succeed(disconnect.lease!), isTrue);
      expect(machine.state.phase, RecordingCardOperationPhase.succeeded);
    });

    test('direct interruption is terminal for the exact lease', () {
      final machine = RecordingCardOperationMachine();
      final transfer = machine.begin(
        kind: RecordingCardOperationKind.bluetoothTransfer,
        origin: RecordingCardOperationOrigin.user,
        connectionRevision: 8,
      );

      expect(machine.interrupt(transfer.lease!), isTrue);
      expect(machine.state.phase, RecordingCardOperationPhase.interrupted);
      expect(machine.state.errorCode, recordingCardOperationSessionChangedCode);
      expect(machine.succeed(transfer.lease!), isFalse);
    });
  });
}
