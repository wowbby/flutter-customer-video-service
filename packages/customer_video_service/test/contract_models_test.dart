import 'dart:convert';

import 'package:customer_video_service/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CallRequest validation', () {
    test('allows omitted fields and 128 Unicode characters', () {
      expect(const CallRequest().validate, returnsNormally);
      expect(CallRequest(businessId: 'a' * 128, scene: '😀' * 128).validate,
          returnsNormally);
    });

    test('rejects empty or whitespace-only optional fields', () {
      for (final value in ['', '  ', '\n\t']) {
        expect(CallRequest(businessId: value).validate, throwsArgumentError);
        expect(CallRequest(scene: value).validate, throwsArgumentError);
      }
    });

    test('rejects more than 128 characters without disclosing the value', () {
      final privateValue = 'private-business-data' * 7;
      for (final request in [
        CallRequest(businessId: privateValue),
        CallRequest(scene: privateValue),
      ]) {
        expect(
          request.validate,
          throwsA(isA<ArgumentError>().having(
            (error) => error.toString(),
            'safe validation message',
            isNot(contains(privateValue)),
          )),
        );
      }
    });
  });

  group('H5 contract', () {
    final context = CallContext(
      sessionId: 'session-1',
      request: const CallRequest(
        businessId: 'private-order-123',
        scene: 'private-support-scene',
      ),
      startedAt: DateTime.parse('2026-11-03T17:00:00+08:00'),
    );

    test('legacy state construction supplies independent state defaults', () {
      const state = CallState(
        sessionId: 'session-1',
        phase: CallPhase.waiting,
        windowMode: CallWindowMode.full,
        probe: false,
        media: CallMediaState(
          muted: false,
          cameraEnabled: true,
          speaker: true,
          remoteUid: null,
          remoteVideo: false,
        ),
        needsToken: false,
        controlBusy: false,
      );
      final bridge = state.toBridgeMap();
      expect(bridge['phase'], 'waiting');
      expect(bridge['connectionState'], 'idle');
      expect(bridge['businessState'], 'none');
      expect(bridge['lastSummary'], isNull);
      expect(state.context, isNull);
    });

    test('summary serializes only safe fields with UTC times and duration', () {
      final summary = CallSummary(
        context: context,
        acceptedAt: DateTime.parse('2026-11-03T17:00:04+08:00'),
        endedAt: DateTime.parse('2026-11-03T17:00:09+08:00'),
        duration: const Duration(milliseconds: 4500),
        reason: CallEndReason.remote,
        releaseStatus: ReleaseStatus.releasedWithWarnings,
        error: const CallException(
          CallErrorCode.sdkError,
          operation: CallOperation.event,
          vendorCode: -123,
          recovery: CallRecovery.retryCall,
        ),
      );

      expect(summary.toBridgeMap(), {
        'sessionId': 'session-1',
        'startedAt': '2026-11-03T09:00:00.000Z',
        'acceptedAt': '2026-11-03T09:00:04.000Z',
        'endedAt': '2026-11-03T09:00:09.000Z',
        'durationMs': 4500,
        'reason': 'remote',
        'releaseStatus': 'releasedWithWarnings',
        'errorCode': 'sdkError',
      });
    });

    test('unanswered summary retains nullable acceptance and duration', () {
      final summary = CallSummary(
        context: context,
        endedAt: DateTime.utc(2026, 11, 3, 9, 1),
        reason: CallEndReason.noAnswer,
        releaseStatus: ReleaseStatus.released,
      );
      final bridge = summary.toBridgeMap();
      expect(bridge['acceptedAt'], isNull);
      expect(bridge['durationMs'], isNull);
      expect(bridge['errorCode'], isNull);
      expect(bridge['reason'], 'noAnswer');
    });

    test('state exposes independent states and summary without request data',
        () {
      final summary = CallSummary(
        context: context,
        endedAt: DateTime.utc(2026, 11, 3, 9, 1),
        reason: CallEndReason.rejected,
        releaseStatus: ReleaseStatus.releaseUnconfirmed,
      );
      final state = _state(
        context: context,
        connectionState: RtcConnectionState.reconnecting,
        businessState: CallBusinessState.accepted,
        summary: summary,
      );
      final bridge = state.toBridgeMap();
      expect(bridge['phase'], 'waiting');
      expect(bridge['connectionState'], 'reconnecting');
      expect(bridge['businessState'], 'accepted');
      expect((bridge['lastSummary'] as Map)['reason'], 'rejected');
      expect((bridge['lastSummary'] as Map)['releaseStatus'],
          'releaseUnconfirmed');
      final json = jsonEncode(bridge);
      for (final sensitive in ['private-', 'businessId', 'scene', 'context']) {
        expect(json, isNot(contains(sensitive)));
      }
    });
  });

  test('exception text exposes the safe code without operation metadata', () {
    const error = CallException(
      CallErrorCode.sdkError,
      operation: CallOperation.renewToken,
      vendorCode: -123456,
      recovery: CallRecovery.restartRequired,
    );
    expect(error.toString(), 'CallException(sdkError)');
    expect(const CallException(CallErrorCode.nativeError).recovery,
        CallRecovery.none);
  });
}

CallState _state({
  CallContext? context,
  RtcConnectionState connectionState = RtcConnectionState.idle,
  CallBusinessState businessState = CallBusinessState.none,
  CallSummary? summary,
}) =>
    CallState(
      sessionId: 'session-1',
      phase: CallPhase.waiting,
      windowMode: CallWindowMode.full,
      probe: false,
      media: const CallMediaState(
        muted: false,
        cameraEnabled: true,
        speaker: true,
        remoteUid: null,
        remoteVideo: false,
      ),
      needsToken: false,
      controlBusy: false,
      context: context,
      connectionState: connectionState,
      businessState: businessState,
      lastSummary: summary,
    );
