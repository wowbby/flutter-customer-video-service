import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:customer_video_service/customer_video_service.dart';
import 'call_manager_test.dart' show FakeTransport;
import 'component_controller_test.dart' show credentials;

String message(String id, String action,
        [Map<String, Object?> params = const {}]) =>
    jsonEncode(
        {'version': 1, 'requestId': id, 'action': action, 'params': params});
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeTransport native;
  late VideoServiceController controller;
  late CustomerH5Bridge bridge;
  setUp(() {
    native = FakeTransport();
    controller = VideoServiceController(
        transport: native, credentialsProvider: (_) async => credentials);
    bridge = CustomerH5Bridge(controller: controller);
  });
  tearDown(() async {
    bridge.dispose();
    controller.dispose();
    await native.stream.close();
  });
  test(
      'external container controls RTC without native WebView methods or leaking credentials',
      () async {
    final sent = <Map<String, Object?>>[];
    final page = bridge.attach(send: (data) {
      sent.add(data);
    });
    expect(sent, isEmpty);
    await page.ready();
    await page.receive(message('start', 'startRtc'));
    expect(native.calls.map((x) => x.$1), ['join']);
    expect(sent.where((x) => x['kind'] == 'response').last['ok'], true);
    expect(jsonEncode(sent), isNot(contains(credentials.token)));
    expect(jsonEncode(sent), isNot(contains(credentials.appId)));
    await controller.hangup();
  });
  test(
      'reload invalidates old bindings and reused request IDs belong to new page',
      () async {
    var opened = 0;
    bridge.dispose();
    bridge = CustomerH5Bridge(
        controller: controller,
        onOpenBusiness: () {
          opened++;
        });
    final old = bridge.attach(send: (_) {});
    await old.ready();
    await old.receive(message('x', 'openBusiness'));
    old.dispose();
    await old.receive(message('y', 'openBusiness'));
    final next = bridge.attach(send: (_) {});
    await next.ready();
    await next.receive(message('x', 'openBusiness'));
    await next.receive(message('x', 'openBusiness'));
    expect(opened, 2);
  });
  test('unready pages and production probe actions are rejected', () async {
    final sent = <Map<String, Object?>>[];
    final page = bridge.attach(send: (m) {
      sent.add(m);
    });
    await page.receive(message('a', 'startRtc'));
    expect(native.calls, isEmpty);
    await page.ready();
    await page.receive(message('b', 'startProbe'));
    expect(sent.last['error'], 'unsupported');
    expect(controller.state.hasWindow, false);
  });
  test('disposed page receives no late response after async credential lookup',
      () async {
    final pending = Completer<CallCredentials>();
    bridge.dispose();
    controller.dispose();
    controller = VideoServiceController(
        transport: native, credentialsProvider: (_) => pending.future);
    bridge = CustomerH5Bridge(controller: controller);
    final sent = <Map<String, Object?>>[];
    final page = bridge.attach(send: (m) {
      sent.add(m);
    });
    await page.ready();
    final request = page.receive(message('x', 'startRtc'));
    page.dispose();
    final before = sent.length;
    pending.complete(credentials);
    await request;
    expect(sent.length, before);
    await controller.hangup();
  });
}
