import 'dart:async' show Completer;
import 'package:customer_rtc/customer_rtc.dart';
import 'package:customer_video_service/customer_video_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'call_manager_test.dart' show FakeTransport, settings;

class PhoneTransport extends FakeTransport implements SystemCallMonitor {
  var phone = SystemCallState.idle;
  final observed = <String>[];
  final stopped = <String>[];
  @override
  Future<SystemCallState> getSystemCallState({String? sessionId}) async {
    if (sessionId != null) observed.add(sessionId);
    return phone;
  }

  @override
  Future<void> endSystemCallObservation(String sessionId) async {
    stopped.add(sessionId);
  }

  void change(String id, SystemCallState state) {
    phone = state;
    emit('systemCallState', id, {'state': state.name});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PhoneTransport native;
  late VideoServiceController controller;
  Completer<CallCredentials>? pendingCredentials;
  var credentialsRequested = 0;
  setUp(() {
    native = PhoneTransport();
    credentialsRequested = 0;
    pendingCredentials = null;
    controller = VideoServiceController(
        transport: native,
        credentialsProvider: (_) async {
          credentialsRequested++;
          if (pendingCredentials != null) return pendingCredentials!.future;
          return settings;
        });
  });
  tearDown(() async {
    await controller.shutdown();
    controller.dispose();
    await native.stream.close();
  });
  final busy = throwsA(isA<CallException>()
      .having((error) => error.code, 'code', CallErrorCode.systemCallBusy));

  for (final phone in [SystemCallState.active, SystemCallState.ringing]) {
    test('busy at entry: ${phone.name}', () async {
      native.phone = phone;
      await expectLater(controller.startCall(), busy);
      expect(credentialsRequested, 0);
      expect(native.calls, isEmpty);
      expect(native.stopped, native.observed);
      expect(controller.state.lastSummary!.reason, CallEndReason.systemCall);
      expect(controller.state.hasWindow, isFalse);
    });
  }
  test('join detects a call that began after preflight', () async {
    native.handler = (method, args) async {
      if (method == 'join') throw PlatformException(code: 'system_call_busy');
      return null;
    };
    await expectLater(controller.startCall(), busy);
    expect(controller.state.lastSummary!.error!.code,
        CallErrorCode.systemCallBusy);
  });
  test(
      'answer while credentials are pending releases observation and blocks late join',
      () async {
    pendingCredentials = Completer<CallCredentials>();
    final starting = controller.startCall();
    await Future<void>.delayed(Duration.zero);
    expect(credentialsRequested, 1);
    native.change(native.observed.single, SystemCallState.active);
    pendingCredentials!.complete(settings);
    await expectLater(starting, busy);
    expect(native.stopped, native.observed);
    expect(native.calls, isEmpty);
    expect(controller.state.lastSummary!.reason, CallEndReason.systemCall);
  });
  test('fresh check blocks acceptance even before a phone event arrives',
      () async {
    final call = await controller.startCall();
    native.phone = SystemCallState.active;
    await expectLater(controller.acceptCall(sessionId: call.sessionId), busy);
    expect(controller.state.lastSummary!.acceptedAt, isNull);
    expect(controller.state.endReason, CallEndReason.systemCall);
  });
  test(
      'pending acceptance cannot override ringing, duplicate acceptance is safe',
      () async {
    final call = await controller.startCall();
    native.change(call.sessionId, SystemCallState.ringing);
    expect(
        () => controller.updateBusinessState(
            sessionId: call.sessionId, state: CallBusinessState.accepted),
        busy);
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.lastSummary!.acceptedAt, isNull);
  });
  test('missed call retains media preferences and session; answered ends once',
      () async {
    native.phone = SystemCallState.unknown;
    final id = (await controller.startCall()).sessionId;
    await controller.acceptCall(sessionId: id);
    await controller.setMuted(true);
    await controller.setSpeaker(false);
    native.change(id, SystemCallState.ringing);
    controller.updateBusinessState(
        sessionId: id, state: CallBusinessState.accepted);
    expect(controller.state.systemCallRinging, isTrue);
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    native.change(id, SystemCallState.idle);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(controller.state.sessionId, id);
    expect(controller.state.media.muted, isTrue);
    expect(controller.state.media.speaker, isFalse);
    expect(controller.state.systemCallRinging, isFalse);
    native.change('old', SystemCallState.active);
    expect(controller.state.sessionId, id);
    native.change(id, SystemCallState.active);
    native.change(id, SystemCallState.active);
    native.change(id, SystemCallState.idle);
    await Future<void>.delayed(Duration.zero);
    expect(native.calls.where((c) => c.$1 == 'join'), hasLength(1));
    expect(native.calls.where((c) => c.$1 == 'leave'), hasLength(1));
    expect(controller.state.lastSummary!.reason, CallEndReason.systemCall);
    expect(controller.state.lastSummary!.error, isNull);
  });
  testWidgets(
      'phone UI may precede ringing; next ordinary background still ends',
      (tester) async {
    final id = (await controller.startCall()).sessionId;
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 50));
    native.change(id, SystemCallState.ringing);
    native.change(id, SystemCallState.idle);
    await tester.pump(const Duration(seconds: 3));
    expect(controller.state.sessionId, id);
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 3));
    expect(controller.state.sessionId, id);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 3));
    expect(controller.state.endReason, CallEndReason.background);
  });
  testWidgets('busy message appears without opening the call UI',
      (tester) async {
    native.phone = SystemCallState.active;
    await tester.pumpWidget(MaterialApp(
        home:
            VideoServiceHost(controller: controller, child: const SizedBox())));
    await expectLater(controller.startCall(), busy);
    await tester.pump();
    expect(find.text('当前正在通话，请结束后再试'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('当前正在通话，请结束后再试'), findsNothing);
  });
}
