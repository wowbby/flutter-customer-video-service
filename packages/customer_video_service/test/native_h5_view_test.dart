import 'package:customer_rtc/customer_rtc.dart';
import 'package:customer_video_service/customer_video_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'call_manager_test.dart' show FakeTransport;
import 'component_bridge_test.dart' show message;

void main() {
  testWidgets(
      'replacing HTML invalidates the old document before the new native view is ready',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('customer_rtc/events'), (_) async => null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('customer_rtc'), (_) async => null);
    final native = FakeTransport();
    final controller = VideoServiceController(
        allowProbe: true,
        transport: native,
        credentialsProvider: (_) async => throw StateError('unused'));
    final bridge = CustomerH5Bridge(controller: controller);
    Future<void> emit(Map<String, Object?> event) async {
      await messenger.handlePlatformMessage('customer_rtc/events',
          const StandardMethodCodec().encodeSuccessEnvelope(event), (_) {});
      await tester.pump();
    }

    await tester.pumpWidget(MaterialApp(
        home: CustomerServiceWebView(bridge: bridge, html: 'first')));
    tester
        .widget<CustomerNativeView>(find.byType(CustomerNativeView))
        .onCreated!(1);
    await emit({'type': 'webReady', 'viewId': 1});
    await tester.pumpWidget(MaterialApp(
        home: CustomerServiceWebView(bridge: bridge, html: 'second')));
    await emit({
      'type': 'bridge',
      'viewId': 1,
      'message': message('old', 'startProbe')
    });
    expect(controller.state.hasWindow, false);
    await emit({'type': 'webReady', 'viewId': 2});
    tester
        .widget<CustomerNativeView>(find.byType(CustomerNativeView))
        .onCreated!(2);
    await emit({
      'type': 'bridge',
      'viewId': 2,
      'message': message('new', 'startProbe')
    });
    expect(controller.state.phase, CallPhase.probe);
    await controller.shutdown();
    await tester.pumpWidget(const SizedBox());
    bridge.dispose();
    controller.dispose();
    await native.stream.close();
    debugDefaultTargetPlatformOverride = null;
  });
}
