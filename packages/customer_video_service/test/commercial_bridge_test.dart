import 'dart:async';
import 'dart:convert';

import 'package:customer_rtc/customer_rtc.dart';
import 'package:customer_video_service/customer_video_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _credentials = CallCredentials(
  appId: '0123456789abcdef0123456789abcdef',
  channel: 'private-channel',
  uid: 7,
  token: 'private-token',
);

String _message(String id, String action,
        [Map<String, Object?> params = const {}]) =>
    jsonEncode(
        {'version': 1, 'requestId': id, 'action': action, 'params': params});

class _Transport implements RtcTransport {
  final stream = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final calls = <(String, Map<String, Object?>)>[];
  @override
  Stream<Map<String, dynamic>> get events => stream.stream;
  @override
  Future<void> invoke(String method, Map<String, Object?> arguments) async {
    calls.add((method, arguments));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Transport native;
  late VideoServiceController controller;
  late CustomerH5Bridge bridge;
  late List<Map<String, Object?>> sent;

  Future<H5Binding> attach() async {
    final binding = bridge.attach(send: sent.add);
    await binding.ready();
    return binding;
  }

  Map<String, Object?> response(String id) => sent.lastWhere(
      (message) => message['kind'] == 'response' && message['requestId'] == id);

  void configure({CredentialsProvider? provider, bool allowProbe = false}) {
    controller = VideoServiceController(
      transport: native,
      allowProbe: allowProbe,
      credentialsProvider: provider ?? (_) async => _credentials,
    );
    bridge = CustomerH5Bridge(controller: controller);
  }

  setUp(() {
    native = _Transport();
    sent = [];
  });
  tearDown(() async {
    bridge.dispose();
    await controller.shutdown();
    controller.dispose();
    await native.stream.close();
  });

  test(
      'late cancelled start response identifies the original call after redial',
      () async {
    final pending = Completer<CallCredentials>();
    var attempts = 0;
    configure(
        provider: (_) =>
            ++attempts == 1 ? pending.future : Future.value(_credentials));
    final page = await attach();
    final firstRequest = _message('first', 'startRtc');
    final starting = page.receive(firstRequest);
    final firstSession = controller.state.sessionId;
    await page
        .receive(_message('cancel', 'hangup', {'sessionId': firstSession}));
    await page.receive(_message('second', 'startRtc'));
    final secondSession = controller.state.sessionId;
    pending.complete(_credentials);
    await starting;

    expect(response('first')['ok'], isTrue);
    expect(response('first')['startResult'],
        {'sessionId': firstSession, 'status': 'cancelled'});
    expect(response('second')['startResult'],
        {'sessionId': secondSession, 'status': 'accepted'});
    expect(secondSession, isNot(firstSession));
    expect((response('first')['result'] as Map)['sessionId'], secondSession);
    expect(native.calls.where((call) => call.$1 == 'join'), hasLength(1));

    await page.receive(firstRequest);
    expect(response('first')['startResult'],
        {'sessionId': firstSession, 'status': 'cancelled'});
    expect(attempts, 2);
  });

  test('reloaded H5 can query the last safe summary after the call ended',
      () async {
    configure();
    final oldPage = await attach();
    final start = await controller.startCall(
        request: const CallRequest(
            businessId: 'private-business-id', scene: 'private-scene'));
    controller.updateBusinessState(
        sessionId: start.sessionId, state: CallBusinessState.accepted);
    await controller.endCall(
        sessionId: start.sessionId, reason: CallEndReason.remote);
    oldPage.dispose();
    sent.clear();
    final page = await attach();
    final initialState = sent.single['state'] as Map;
    await page.receive(_message('query', 'getState'));
    final snapshot = response('query')['result'] as Map;
    expect(snapshot, initialState);
    expect(snapshot['sessionId'], isNull);
    expect(snapshot['connectionState'], 'idle');
    expect(snapshot['businessState'], 'ended');
    final summary = snapshot['lastSummary'] as Map;
    expect(summary.keys.toSet(), {
      'sessionId',
      'startedAt',
      'acceptedAt',
      'endedAt',
      'reason',
      'durationMs',
      'releaseStatus',
      'errorCode',
    });
    expect(summary['sessionId'], start.sessionId);
    expect(summary['reason'], 'remote');
    expect(summary['releaseStatus'], 'released');
    expect(summary['durationMs'], isA<int>());
    expect(summary['errorCode'], isNull);
    expect(jsonEncode(sent), isNot(contains('private')));
    expect(jsonEncode(sent), isNot(contains(_credentials.appId)));
    expect(jsonEncode(native.calls.map((call) => call.$2).toList()),
        isNot(contains('private-business-id')));
  });

  test('H5 cannot inject request metadata or declare business acceptance',
      () async {
    CallContext? context;
    configure(provider: (value) async {
      context = value;
      return _credentials;
    });
    final page = await attach();
    await page.receive(_message('start', 'startRtc', {
      'businessId': 'web-business-id',
      'scene': 'web-scene',
      'businessState': 'accepted',
    }));
    expect(context!.request.businessId, isNull);
    expect(context!.request.scene, isNull);
    expect(controller.state.businessState, CallBusinessState.requested);
    for (final action in ['updateBusinessState', 'accept', 'endCall']) {
      await page.receive(_message(action, action, {
        'sessionId': context!.sessionId,
        'state': 'accepted',
      }));
      expect(response(action)['error'], 'unknownAction');
    }
    expect(controller.state.businessState, CallBusinessState.requested);
    expect(jsonEncode(sent), isNot(contains('web-business-id')));
    expect(jsonEncode(sent), isNot(contains(_credentials.token)));
  });

  test('raw SDK error text and credentials never appear in H5 summaries',
      () async {
    configure();
    final page = await attach();
    await page.receive(_message('start', 'startRtc'));
    native.stream.add({
      'type': 'error',
      'sessionId': controller.state.sessionId,
      'code': 'agora_-7',
      'message': 'private-error-with-token=${_credentials.token}',
    });
    await Future<void>.delayed(Duration.zero);
    await page.receive(_message('query', 'getState'));
    final snapshot = response('query')['result'] as Map;
    expect((snapshot['lastSummary'] as Map)['errorCode'], 'sdkError');
    expect(jsonEncode(sent), isNot(contains('private')));
    expect(jsonEncode(sent), isNot(contains(_credentials.appId)));
  });

  test('probe retains v1 response shape and existing snapshot fields',
      () async {
    configure(allowProbe: true);
    final page = await attach();
    await page.receive(_message('probe', 'startProbe'));
    expect(response('probe')['ok'], isTrue);
    expect(response('probe').containsKey('startResult'), isFalse);
    final snapshot = response('probe')['result'] as Map;
    expect(snapshot['phase'], 'probe');
    expect(snapshot['probe'], isTrue);
    expect(
        snapshot.keys,
        containsAll([
          'sessionId',
          'phase',
          'mode',
          'probe',
          'muted',
          'cameraEnabled',
          'speaker',
          'remoteUid',
          'remoteVideo',
          'needsToken',
          'errorCode',
          'endReason',
        ]));
    expect(native.calls, isEmpty);
  });
}
