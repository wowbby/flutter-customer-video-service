import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:customer_video_service/customer_video_service.dart';
import 'package:minimal_video_service_host/main.dart';

void main() {
  testWidgets('host starts a waiting call and keeps its session across routes',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('customer_rtc/events'), (_) async => null);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('customer_rtc'),
        (call) async => call.method == 'getSystemCallState' ? 'idle' : null);
    final controller = VideoServiceController();
    await tester.pumpWidget(MinimalVideoHost(controller: controller));
    await tester.tap(find.text('开始等待客服'));
    await tester.pumpAndSettle();
    final sessionId = controller.state.sessionId;
    expect(sessionId, isNotNull);
    expect(controller.state.phase, CallPhase.waiting);
    controller.minimize();
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开业务页'));
    await tester.pumpAndSettle();
    expect(find.text('宿主业务页'), findsOneWidget);
    expect(controller.state.sessionId, sessionId);
    expect(controller.state.windowMode, CallWindowMode.mini);
    controller.restore();
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.state.hasWindow, isFalse);
    expect(controller.state.lastSummary?.context.sessionId, sessionId);
    await controller.shutdown();
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

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
