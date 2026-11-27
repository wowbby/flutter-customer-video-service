import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:customer_video_service/customer_video_service.dart';
import 'call_manager_test.dart' show FakeTransport;
import 'component_controller_test.dart' show credentials;
import 'component_bridge_test.dart' show message;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeTransport native;
  late VideoServiceController controller;
  late CustomerH5Bridge bridge;
  late H5Binding page;
  final sent = <Map<String, Object?>>[];
  Future<Map<String, Object?>> reply(String body) async {
    await page.receive(body);
    return sent.lastWhere((m) => m['kind'] == 'response');
  }

  setUp(() async {
    sent.clear();
    native = FakeTransport();
    controller = VideoServiceController(
        transport: native,
        allowProbe: true,
        credentialsProvider: (_) async => credentials);
    bridge = CustomerH5Bridge(controller: controller);
    page = bridge.attach(send: sent.add);
    await page.ready();
  });
  tearDown(() async {
    bridge.dispose();
    controller.dispose();
    await native.stream.close();
  });
  test('v1 probe lifecycle and stale-session guard', () async {
    expect((await reply(message('a', 'startProbe')))['ok'], true);
    final old = controller.state.sessionId;
    await reply(message('b', 'minimize', {'sessionId': old}));
    expect(controller.state.windowMode, CallWindowMode.mini);
    await reply(message('c', 'hangup', {'sessionId': old}));
    await controller.startProbe();
    expect((await reply(message('d', 'hangup', {'sessionId': old})))['error'],
        'staleSession');
    expect(controller.state.hasWindow, true);
  });
  test('request conflicts and malformed payloads never launch calls', () async {
    await reply(message('same', 'getState'));
    expect((await reply(message('same', 'startProbe')))['error'],
        'requestConflict');
    for (final body in ['not-json', '[]', '{"version":2}', 'x' * 9000]) {
      expect((await reply(body))['error'], 'invalidRequest');
    }
    expect(controller.state.hasWindow, false);
  });
  test('fresh page queries existing session without another native join',
      () async {
    await controller.startCall();
    final id = controller.state.sessionId;
    page.dispose();
    page = bridge.attach(send: sent.add);
    await page.ready();
    final response = await reply(message('q', 'getState'));
    expect((response['result'] as Map)['sessionId'], id);
    expect(native.calls.where((c) => c.$1 == 'join'), hasLength(1));
    expect(jsonEncode(sent), isNot(contains(credentials.token)));
    await controller.hangup();
  });
  test('hangup and failed join cannot report successful native cleanup',
      () async {
    await controller.startCall();
    native.handler = (method, _) async {
      if (method == 'leave') throw PlatformException(code: 'cleanup_failed');
      return null;
    };
    expect(
        (await reply(message('end', 'hangup',
            {'sessionId': controller.state.sessionId})))['error'],
        'cleanupFailed');
    expect(controller.state.phase, CallPhase.ending);
    native.handler = null;
    await controller.hangup();
    native.handler = (method, _) async {
      throw PlatformException(
          code: method == 'join' ? 'rtc_join_failed' : 'cleanup_failed');
    };
    expect(
        (await reply(message('start', 'startRtc')))['error'], 'cleanupFailed');
  });
}
