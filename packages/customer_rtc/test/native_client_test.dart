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
  test('RTC consumers share one subscription until the last listener leaves',
      () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final operations = <String>[];
    const channel = MethodChannel('customer_rtc/events');
    messenger.setMockMethodCallHandler(channel, (call) async {
      operations.add(call.method);
      return null;
    });
    try {
      final first = NativeRtcClient().events.listen((_) {});
      final received = <Map<String, dynamic>>[];
      final second = NativeRtcClient().events.listen(received.add);
      await Future<void>.delayed(Duration.zero);
      expect(operations, ['listen']);
      await first.cancel();
      final packet = const StandardMethodCodec()
          .encodeSuccessEnvelope({'type': 'joined', 'sessionId': 'one'});
      await messenger.handlePlatformMessage(channel.name, packet, (_) {});
      await Future<void>.delayed(Duration.zero);
      expect(operations, ['listen']);
      expect(received.single['type'], 'joined');
      await second.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(operations, ['listen', 'cancel']);
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
