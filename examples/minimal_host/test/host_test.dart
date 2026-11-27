import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:customer_video_service/customer_video_service.dart';
import 'package:minimal_video_service_host/main.dart';

void main() {
  testWidgets(
      'public package keeps the same video view through host route changes',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('customer_rtc/events'), (_) async => null);
    final controller = VideoServiceController(
        allowProbe: true,
        credentialsProvider: (_) async => throw StateError('unused'));
    await tester.pumpWidget(MinimalVideoHost(controller: controller));
    await controller.startProbe();
    controller.minimize();
    await tester.pumpAndSettle();
    final before = tester.element(find.byKey(const ValueKey('remote-video')));
    await tester.tap(find.text('打开业务页'));
    await tester.pumpAndSettle();
    expect(find.text('宿主业务页'), findsOneWidget);
    expect(
        identical(
            before, tester.element(find.byKey(const ValueKey('remote-video')))),
        true);
    expect(controller.state.phase, CallPhase.probe);
    await controller.shutdown();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remote-video')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}
