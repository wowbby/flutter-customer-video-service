import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:customer_rtc/customer_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native leave result preserves confirmed release warnings', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('customer_rtc'),
        (call) async => {'releaseStatus': 'releasedWithWarnings'});
    try {
      expect(await NativeRtcClient().invoke('leave', {'sessionId': 'one'}),
          {'releaseStatus': 'releasedWithWarnings'});
    } finally {
      messenger.setMockMethodCallHandler(
          const MethodChannel('customer_rtc'), null);
    }
  });
  test(
      'RTC and Web adapters share one native subscription and cancel only after both leave',
      () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final operations = <String>[];
    final replies = <MethodCall>[];
    messenger.setMockMethodCallHandler(
        const MethodChannel('customer_rtc/events'), (call) async {
      operations.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('customer_rtc'),
        (call) async {
      replies.add(call);
      return null;
    });
    final rtc = NativeRtcClient();
    final web = NativeWebClient();
    final messages = <NativeWebEvent>[];
    final a = rtc.events.listen((_) {});
    final b = web.events.listen(messages.add);
    await Future<void>.delayed(Duration.zero);
    expect(operations, ['listen']);
    final envelope = const StandardMethodCodec()
        .encodeSuccessEnvelope({'type': 'webReady', 'viewId': 7});
    await messenger.handlePlatformMessage(
        'customer_rtc/events', envelope, (_) {});
    await Future<void>.delayed(Duration.zero);
    expect(messages.single.type, NativeWebEventType.ready);
    await a.cancel();
    expect(operations, ['listen']);
    await web.reply(7, {
      'kind': 'state',
      'state': {'phase': 'idle'}
    });
    expect(replies.single.method, 'webReply');
    expect(
        jsonDecode((replies.single.arguments as Map)['json'] as String)['kind'],
        'state');
    await b.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(operations, ['listen', 'cancel']);
    messenger.setMockMethodCallHandler(
        const MethodChannel('customer_rtc/events'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('customer_rtc'), null);
  });
}
