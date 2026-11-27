import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:customer_video_service/customer_video_service.dart';
import 'call_manager_test.dart' show FakeTransport, settings;

void main() {
  testWidgets('full call isolates business focus and semantics until minimized',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final transport = FakeTransport();
    final controller = VideoServiceController(
        allowProbe: true,
        transport: transport,
        credentialsProvider: (_) async => settings);
    final focus = FocusNode();
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(MaterialApp(
          builder: (_, child) =>
              VideoServiceHost(controller: controller, child: child!),
          home: Scaffold(
              body: Column(children: [
            TextField(focusNode: focus),
            TextButton(onPressed: () {}, child: const Text('业务操作')),
          ]))));
      await tester.showKeyboard(find.byType(TextField));
      expect(focus.hasFocus, true);
      await controller.startProbe();
      await tester.pump();
      await tester.pump();
      expect(focus.hasFocus, false);
      expect(focus.canRequestFocus, false);
      expect(find.semantics.byLabel('业务操作'), findsNothing);
      expect(find.byTooltip('缩小窗口'), findsOneWidget);
      controller.minimize();
      await tester.pump();
      expect(find.semantics.byLabel('业务操作'), findsOneWidget);
      await tester.showKeyboard(find.byType(TextField));
      expect(focus.hasFocus, true);
    } finally {
      await controller.hangup();
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      focus.dispose();
      semantics.dispose();
      await transport.stream.close();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'iOS restores an imperative status bar after minimizing and ending',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final transport = FakeTransport();
    final controller = VideoServiceController(
        transport: transport, credentialsProvider: (_) async => settings);
    final messenger = tester.binding.defaultBinaryMessenger;
    try {
      messenger.setMockMethodCallHandler(
          SystemChannels.platform_views, (_) async => null);
      SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
      await tester.pumpWidget(MaterialApp(
          builder: (_, child) =>
              VideoServiceHost(controller: controller, child: child!),
          home: const Scaffold(body: SizedBox.expand())));
      await tester.pump();
      await controller.startCall();
      await tester.pump();
      expect(SystemChrome.latestStyle?.statusBarBrightness, Brightness.dark);
      controller.minimize();
      await tester.pump();
      expect(SystemChrome.latestStyle?.statusBarBrightness, Brightness.light);
      controller.restore();
      await tester.pump();
      expect(SystemChrome.latestStyle?.statusBarBrightness, Brightness.dark);
      await controller.hangup();
      await tester.pump();
      expect(SystemChrome.latestStyle?.statusBarBrightness, Brightness.light);
    } finally {
      await controller.hangup();
      await tester.pumpWidget(const SizedBox());
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      controller.dispose();
      await transport.stream.close();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'full media reaches both system bars while the controls avoid cutouts and IME',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    tester.view.viewPadding = const FakeViewPadding(top: 59, bottom: 34);
    tester.view.padding = tester.view.viewPadding;
    final transport = FakeTransport();
    final controller = VideoServiceController(
        transport: transport, credentialsProvider: (_) async => settings);
    final session = (await controller.startCall()).sessionId;
    const hostStyle = SystemUiOverlayStyle.dark;
    List<bool?> fullscreenTransitions() => transport.calls
        .where((event) => event.$1 == 'setFlutterCallFullscreen')
        .map((event) => event.$2['fullscreen'] as bool?)
        .toList();
    SystemUiOverlayStyle? styleAt(Offset point) =>
        tester.binding.renderViews.single.debugLayer!
            .find<SystemUiOverlayStyle>(point);
    final screen = Offset.zero & const Size(393, 852);
    final primary = find.byKey(const ValueKey('remote-video'));
    final minimize = find.byTooltip('缩小窗口');
    try {
      await tester.pumpWidget(MaterialApp(
          builder: (_, child) =>
              VideoServiceHost(controller: controller, child: child!),
          home: const AnnotatedRegion<SystemUiOverlayStyle>(
              value: hostStyle, child: SizedBox.expand())));
      final background = find.byWidgetPredicate((widget) =>
          widget is DecoratedBox &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).image?.image is AssetImage);
      expect(tester.getRect(background), screen);
      expect(tester.getRect(minimize).top, greaterThanOrEqualTo(59));
      expect(tester.getRect(find.text('取消')).bottom, lessThanOrEqualTo(818));
      expect(styleAt(const Offset(190, 5))?.statusBarColor, Colors.transparent);
      expect(styleAt(const Offset(190, 849))?.systemNavigationBarIconBrightness,
          Brightness.light);
      expect(fullscreenTransitions(), [true]);

      controller.updateBusinessState(
          sessionId: session, state: CallBusinessState.accepted);
      await tester.pump();
      final originalVideo = tester.element(primary);
      expect(tester.getRect(primary), screen);
      await controller.toggleCallOrientation();
      await tester.pump();
      Finder physicalScrim(Alignment edge) => find.byWidgetPredicate((widget) {
            if (widget is! DecoratedBox ||
                widget.decoration is! BoxDecoration) {
              return false;
            }
            final gradient = (widget.decoration as BoxDecoration).gradient;
            return gradient is LinearGradient &&
                gradient.begin == edge &&
                gradient.colors.first == Colors.black54;
          });
      expect(tester.getRect(physicalScrim(Alignment.topCenter)),
          const Rect.fromLTWH(0, 0, 393, 67));
      tester.view.viewInsets = const FakeViewPadding(bottom: 18);
      tester.view.padding = const FakeViewPadding(top: 59, bottom: 16);
      await tester.pump();
      expect(tester.getRect(physicalScrim(Alignment.bottomCenter)),
          const Rect.fromLTWH(0, 810, 393, 42));
      expect(tester.getRect(primary), rectMoreOrLessEquals(screen));
      await controller.toggleCallOrientation();
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 322);
      tester.view.padding = const FakeViewPadding(top: 59);
      await tester.pump();
      expect(tester.getRect(primary), screen);
      expect(tester.getRect(find.text('挂断')).bottom, lessThanOrEqualTo(530));
      await tester.tap(minimize);
      await tester.pump();
      expect(tester.getRect(find.bySemanticsLabel('通话中')).bottom,
          lessThanOrEqualTo(530));
      expect(styleAt(const Offset(190, 5)), hostStyle);
      expect(styleAt(const Offset(190, 849)), hostStyle);
      tester.view.resetViewInsets();
      tester.view.physicalSize = const Size(852, 393);
      tester.view.viewPadding =
          const FakeViewPadding(left: 59, right: 30, bottom: 21);
      tester.view.padding = tester.view.viewPadding;
      controller.restore();
      await tester.pump();
      expect(tester.getRect(primary), const Rect.fromLTWH(0, 0, 852, 393));
      expect(tester.getRect(minimize).left, greaterThanOrEqualTo(59));
      expect(tester.getRect(find.text('清晰度')).right, lessThanOrEqualTo(822));
      expect(tester.getRect(find.text('挂断')).bottom, lessThanOrEqualTo(372));
      expect(tester.element(primary), same(originalVideo));
      await controller.hangup();
      await tester.pump();
      expect(styleAt(const Offset(200, 390)), hostStyle);
      expect(fullscreenTransitions(), [true, false, true, false]);
    } finally {
      await controller.hangup();
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await transport.stream.close();
      tester.view.reset();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'tap mini video restores full screen without replacing view elements',
      (tester) async {
    // Use unsupported native host in widget tests; the actual video child remains IgnorePointer.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final transport = FakeTransport();
    final semantics = tester.ensureSemantics();
    final manager = VideoServiceController(
        transport: transport,
        allowProbe: true,
        credentialsProvider: (_) async => throw StateError('unused'));
    await manager.startProbe();
    manager.minimize();
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) =>
          VideoServiceHost(controller: manager, child: child!),
      home: const Scaffold(body: Text('underlying page')),
    ));
    final video = find.byKey(const ValueKey('remote-video'));
    expect(tester.getSemantics(find.bySemanticsLabel('无媒体测试')).rect.width, 84,
        reason: 'Floating window semantics must not absorb the entire page');
    final before = tester.element(video);
    await tester.tapAt(tester.getCenter(video));
    await tester.pump();
    expect(manager.state.windowMode == CallWindowMode.mini, false);
    expect(identical(tester.element(video), before), true);
    semantics.dispose();
    await manager.hangup();
    await tester.pumpWidget(const SizedBox());
    manager.dispose();
    await transport.stream.close();
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets('RTC preview and answered card use the remote primary canvas',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final transport = FakeTransport();
    final manager = VideoServiceController(
        mediaOnlyPreview: true,
        transport: transport,
        credentialsProvider: (_) async => settings);
    final session = (await manager.startCall()).sessionId;
    try {
      manager.minimize();
      await tester.pumpWidget(MaterialApp(
          builder: (_, child) =>
              VideoServiceHost(controller: manager, child: child!),
          home: const Scaffold()));
      final remote = find.byKey(const ValueKey('remote-video'));
      final local = find.byKey(const ValueKey('local-video'));
      final originalRemote = tester.element(remote);
      final originalLocal = tester.element(local);
      final avatar = find.image(const AssetImage('assets/service_avatar.png',
          package: 'customer_video_service'));
      transport.emit('remoteJoined', session, {'uid': 15});
      await tester.pump();
      final preview = find.bySemanticsLabel('通话中');
      final initialBounds = tester.getRect(preview);
      expect(initialBounds.size, const Size(84, 150));
      expect(avatar, findsOneWidget);
      expect(manager.connectedDuration, isNull);
      transport.emit('remoteVideo', session, {'uid': 15});
      await tester.pump();
      expect(avatar, findsNothing);
      expect(tester.getRect(remote), initialBounds);
      transport.emit('networkQuality', session,
          {'uid': 0, 'txQuality': 3, 'rxQuality': 2});
      await tester.pump();
      expect(find.text('当前你的网络不佳'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('当前你的网络不佳'), findsNothing);
      transport.emit('networkQuality', session,
          {'uid': 15, 'txQuality': 4, 'rxQuality': 2});
      await tester.pump();
      expect(find.text('当前双方网络不佳'), findsOneWidget);
      transport.emit('networkQuality', session,
          {'uid': 15, 'txQuality': 1, 'rxQuality': 1});
      await tester.pump();
      expect(find.text('当前双方网络不佳'), findsNothing);
      expect(find.text('当前你的网络不佳'), findsNothing);
      expect(tester.getRect(find.bySemanticsLabel('通话中')), initialBounds);
      expect(avatar, findsNothing);
      expect(find.text('挂断'), findsNothing);
      double opacity(Finder video) => tester
          .widget<Opacity>(
              find.ancestor(of: video, matching: find.byType(Opacity)).first)
          .opacity;
      expect(opacity(remote), 1);
      expect(opacity(local), 0);
      transport.emit('connection', session, {'state': 'reconnecting'});
      await tester.pump();
      expect(tester.getRect(preview), initialBounds);
      expect(avatar, findsOneWidget);
      expect(find.text('全屏'), findsNothing);
      expect(find.textContaining(RegExp(r'^\d{2}:\d{2}$')), findsOneWidget);
      transport.emit('connection', session, {'state': 'connected'});
      await tester.pump();
      expect(find.text('挂断'), findsNothing);
      manager.updateBusinessState(
          sessionId: session, state: CallBusinessState.accepted);
      await tester.pump();
      expect(tester.getRect(find.bySemanticsLabel('通话中')), initialBounds);
      transport.emit('networkQuality', session,
          {'uid': 0, 'txQuality': 1, 'rxQuality': 1});
      await tester.pump();
      expect(tester.getRect(find.bySemanticsLabel('通话中')), initialBounds);
      expect(find.text('弱网'), findsNothing);
      expect(tester.element(remote), same(originalRemote));
      expect(tester.element(local), same(originalLocal));
      expect(find.text('视频预览'), findsNothing);
      expect(find.textContaining(RegExp(r'^\d{2}:\d{2}$')), findsOneWidget);
      expect(avatar, findsNothing);
    } finally {
      await manager.hangup();
      await tester.pumpWidget(const SizedBox());
      manager.dispose();
      await transport.stream.close();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('waiting, queue and accepted call use the same video surfaces',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 812);
    tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 34);
    tester.view.padding = tester.view.viewPadding;
    final transport = FakeTransport();
    final manager = VideoServiceController(
        transport: transport,
        mediaOptions: const CallMediaOptions(
            primaryVideo: VideoRole.local, videoQuality: VideoQuality.sd),
        credentialsProvider: (_) async => settings);
    final call = await manager.startCall();
    final session = call.sessionId;
    try {
      await tester.pumpWidget(MaterialApp(
          builder: (context, child) =>
              VideoServiceHost(controller: manager, child: child!),
          home: const Scaffold()));
      final primary = find.byKey(const ValueKey('local-video'));
      final secondary = find.byKey(const ValueKey('remote-video'));
      final originallyMounted = tester.element(primary);
      final originalInset = tester.element(secondary);
      final waitLabel = find.text('等待坐席接听，请稍等…');
      expect(waitLabel, findsOneWidget);
      expect(tester.getTopLeft(waitLabel).dy, closeTo(370, .01));
      expect(tester.getTopLeft(find.text('取消')).dy, closeTo(744, .01));
      final avatar = tester.getRect(find.image(const AssetImage(
          'assets/service_avatar.png',
          package: 'customer_video_service')));
      // Image includes the transparent/shadow margin of the exported asset.
      expect(avatar.center, const Offset(187.5, 300));
      expect(avatar.width, closeTo(129.5, .01));
      expect(find.text('取消'), findsOneWidget);
      expect(
          find.image(const AssetImage(
              'assets/call_icons/call_minimize_wait.png',
              package: 'customer_video_service')),
          findsOneWidget);
      expect(find.text('通话时长'), findsNothing);
      manager.updateQueue(
          sessionId: session,
          peopleAhead: 1,
          estimatedWait: const Duration(minutes: 5));
      transport.emit('joined', session, {'uid': 42});
      transport.emit('remoteJoined', session, {'uid': 23});
      transport.emit('remoteVideo', session, {'uid': 23});
      await tester.pump();
      expect(find.textContaining('前面还有1人'), findsOneWidget);
      expect(find.text('麦克风已开'), findsNothing);
      await tester.tap(find.byTooltip('缩小窗口'));
      await tester.pump();
      final card = find.bySemanticsLabel('等待接听');
      expect(tester.getRect(card), const Rect.fromLTWH(275, 105, 84, 150));
      final cardImage = tester.getRect(find.image(const AssetImage(
          'assets/service_avatar.png',
          package: 'customer_video_service')));
      expect(cardImage.width * 180 / 259, closeTo(58, .01));
      expect(cardImage.center.dx, closeTo(275 + 42, .01));
      expect(cardImage.center.dy - 15.5 * 58 / 180, closeTo(105 + 64, .01));
      expect(find.text('等待接听'), findsOneWidget);
      expect(find.text('取消'), findsNothing);
      expect(find.textContaining('前面还有1人'), findsNothing);
      expect(tester.element(primary), same(originallyMounted));
      expect(tester.element(secondary), same(originalInset));
      await tester.dragFrom(tester.getCenter(card), const Offset(-225, 160));
      await tester.pump();
      expect(manager.state.windowMode, CallWindowMode.mini);
      expect(tester.getTopLeft(card).dx, 16);
      expect(tester.getTopLeft(card).dy, greaterThan(105));
      tester.view.viewInsets = const FakeViewPadding(bottom: 500);
      await tester.pump();
      expect(tester.getRect(card).bottom, lessThanOrEqualTo(312));
      tester.view.resetViewInsets();
      await tester.pump();
      await tester.tap(find.text('等待接听'));
      await tester.pump();
      expect(manager.state.windowMode, CallWindowMode.full);
      expect(find.textContaining('前面还有1人'), findsOneWidget);
      manager.minimize();
      await tester.pump();
      final draggedRect = tester.getRect(card);
      manager.updateBusinessState(
          sessionId: session, state: CallBusinessState.accepted);
      await tester.pump();
      expect(card, findsNothing);
      expect(manager.state.windowMode, CallWindowMode.mini);
      final activeCard = find.bySemanticsLabel('通话中');
      final clock = find.textContaining(RegExp(r'^\d{2}:\d{2}$'));
      final agentAvatar = find.image(const AssetImage(
          'assets/service_avatar.png',
          package: 'customer_video_service'));
      expect(tester.getRect(activeCard), draggedRect);
      expect(tester.getRect(secondary), draggedRect);
      expect(agentAvatar, findsNothing);
      expect(find.text('挂断'), findsNothing);
      expect(clock, findsOneWidget);
      transport.emit('mediaTrackState', session,
          {'track': 'remoteVideo', 'uid': 23, 'state': 0, 'reason': 5});
      await tester.pump();
      expect(agentAvatar, findsOneWidget);
      expect(clock, findsOneWidget);
      expect(tester.getRect(activeCard), draggedRect);
      transport.emit('mediaTrackState', session,
          {'track': 'remoteVideo', 'uid': 23, 'state': 2, 'reason': 0});
      transport.emit('remoteVideo', session, {'uid': 23});
      await tester.pump();
      expect(agentAvatar, findsNothing);
      expect(tester.element(secondary), same(originalInset));
      expect(tester.element(primary), same(originallyMounted));
      await tester.tap(clock);
      await tester.pump();
      expect(find.text('通话时长'), findsOneWidget);
      expect(find.text('挂断'), findsOneWidget);
      expect(tester.getRect(secondary), const Rect.fromLTWH(275, 105, 84, 150));
      final callSize = tester.getSize(primary);
      final insetSize = tester.getSize(secondary);
      await tester.tap(find.bySemanticsLabel('切换到对方主画面'));
      await tester.pump();
      expect(tester.getSize(secondary), callSize);
      expect(tester.getSize(primary), insetSize);
      expect(tester.element(primary), same(originallyMounted));
      expect(tester.element(secondary), same(originalInset));
      await manager.setCameraEnabled(false);
      await tester.pump();
      expect(find.bySemanticsLabel('用户头像'), findsOneWidget);
      expect(agentAvatar, findsNothing);
      transport.emit('mediaTrackState', session,
          {'track': 'remoteVideo', 'uid': 23, 'state': 0, 'reason': 5});
      await tester.pump();
      expect(tester.getCenter(agentAvatar).dx, closeTo(callSize.width / 2, 1));
      transport.emit('mediaTrackState', session,
          {'track': 'remoteVideo', 'uid': 23, 'state': 2, 'reason': 0});
      transport.emit('remoteVideo', session, {'uid': 23});
      await manager.setCameraEnabled(true);
      await tester.pump();
      expect(agentAvatar, findsNothing);
      manager.minimize();
      await tester.pump();
      expect(tester.getRect(secondary), tester.getRect(activeCard));
      expect(find.bySemanticsLabel('切换到本机主画面'), findsNothing);
      await tester.tap(activeCard);
      await tester.pump();
      expect(tester.getSize(secondary), callSize);
      await tester.tap(find.bySemanticsLabel('切换到本机主画面'));
      await tester.pump();
      expect(tester.getSize(secondary), insetSize);
      expect(tester.element(primary), same(originallyMounted));
      expect(tester.element(secondary), same(originalInset));
      tester.view.physicalSize = const Size(320, 700);
      await tester.pump();
      final narrowInset = tester.getRect(secondary);
      expect(narrowInset, const Rect.fromLTWH(220, 105, 84, 150));
      manager.minimize();
      await tester.pump();
      expect(tester.getSize(activeCard), narrowInset.size);
      await tester.tap(activeCard);
      tester.view.physicalSize = const Size(375, 812);
      await tester.pump();
      Finder glyph(String name) =>
          find.image(AssetImage('assets/call_icons/call_$name.png',
              package: 'customer_video_service'));
      for (final name in [
        'mic',
        'speaker',
        'camera',
        'rotate',
        'end',
        'flip',
      ]) {
        expect(tester.getSize(glyph(name)), const Size.square(27.5),
            reason: name);
      }
      expect(tester.getSize(glyph('minimize')), const Size.square(24));
      expect(tester.getSize(glyph('quality_arrow')), const Size.square(9));
      final micCircle = find
          .ancestor(of: glyph('mic'), matching: find.byType(Container))
          .first;
      expect(tester.getRect(micCircle), const Rect.fromLTWH(51, 591, 55, 55));
      expect(tester.element(primary), same(originallyMounted));
      expect(tester.element(secondary), same(originalInset));
      await tester.tap(find.text('麦克风已开'));
      await tester.pump();
      expect(manager.state.media.muted, isTrue);
      expect(find.text('麦克风已关'), findsOneWidget);
      await tester.tap(find.text('标清'));
      await tester.pump();
      final menuRow = find
          .ancestor(of: find.text('高清'), matching: find.byType(InkWell))
          .first;
      expect(tester.getRect(menuRow), const Rect.fromLTWH(243, 152, 120, 48));
      await tester.tapAt(const Offset(20, 300));
      await tester.pump();
      expect(find.text('高清'), findsNothing);
      await tester.tap(find.text('标清'));
      await tester.pump();
      await tester.tapAt(const Offset(303, 128)); // Already selected.
      await tester.pump();
      expect(find.text('高清'), findsNothing);
      expect(transport.calls.where((c) => c.$1 == 'setVideoQuality'), isEmpty);
      await tester.tap(find.text('标清'));
      await tester.pump();
      await tester.tap(find.text('高清'));
      await tester.pump();
      expect(manager.state.media.quality, VideoQuality.hd);
      expect(transport.calls.where((c) => c.$1 == 'setVideoQuality'),
          hasLength(1));
      await tester.tap(find.text('高清'));
      await tester.pump();
      manager.minimize();
      await tester.pump();
      manager.restore();
      await tester.pump();
      expect(find.text('标清'), findsNothing);
      await tester.tap(find.text('切换横屏'));
      await tester.pump();
      expect(manager.callViewRotated, isTrue);
      expect(find.text('切换竖屏'), findsOneWidget);
      expect(tester.element(secondary), same(originalInset));
      await tester.tap(find.byTooltip('缩小窗口'));
      await tester.pump();
      expect(manager.callViewRotated, isFalse);
      expect(manager.state.windowMode, CallWindowMode.mini);
      expect(tester.element(primary), same(originallyMounted));
      expect(tester.takeException(), isNull);
    } finally {
      await manager.hangup();
      await tester.pumpWidget(const SizedBox());
      manager.dispose();
      await transport.stream.close();
      tester.view.reset();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
