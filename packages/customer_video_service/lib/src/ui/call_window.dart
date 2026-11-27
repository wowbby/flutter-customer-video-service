import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;
import 'package:customer_rtc/customer_rtc.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChrome, SystemUiOverlayStyle;
import '../controller.dart';
import '../models.dart';
import 'window_options.dart';
import '../call/window_geometry.dart';

part 'call_widgets.dart';

String callPhaseLabel(CallPhase phase) => switch (phase) {
      CallPhase.idle => '未发起',
      CallPhase.probe => '窗口交互测试 · 无媒体',
      CallPhase.joining => '请求权限 / 加入频道',
      CallPhase.waiting => '等待对端加入',
      CallPhase.connecting => '对端已加入 · 等待视频',
      CallPhase.connected => '已收到远端视频',
      CallPhase.reconnecting => '网络重连中',
      CallPhase.ending => '正在结束 / 释放资源',
    };

class VideoServiceHost extends StatefulWidget {
  const VideoServiceHost(
      {super.key,
      required this.controller,
      required this.child,
      this.options = const CallWindowOptions()});
  final VideoServiceController controller;
  final Widget child;
  final CallWindowOptions options;
  @override
  State<VideoServiceHost> createState() => _VideoServiceHostState();
}

class _VideoServiceHostState extends State<VideoServiceHost> {
  Offset? position;
  String? dragSession;
  @override
  Widget build(BuildContext context) {
    widget.options.validate();
    return Overlay.wrap(
        child: AnimatedBuilder(
            animation: widget.controller,
            builder: (context, _) {
              final m = widget.controller;
              // Physical safe edges remain fixed while the keyboard animates.
              final padding = MediaQuery.viewPaddingOf(context);
              final obscured = MediaQuery.viewInsetsOf(context);
              return LayoutBuilder(builder: (context, size) {
                final mini = m.state.windowMode == CallWindowMode.mini;
                final compactCard = mini &&
                    (m.miniElapsedDuration != null ||
                        ((m.awaitingAnswer || m.previewMiniCard) &&
                            widget.options.noticeBuilder == null &&
                            widget.options.controlsBuilder == null &&
                            widget.options.phaseLabelBuilder == null));
                final rotated = !mini && m.callViewRotated;
                final avoid = EdgeInsets.fromLTRB(
                    math.max(padding.left, obscured.left),
                    math.max(padding.top, obscured.top),
                    math.max(padding.right, obscured.right),
                    math.max(padding.bottom, obscured.bottom));
                final safe = mini ? EdgeInsets.zero : avoid;
                Rect windowRect(Offset? origin) => callWindowRect(
                    size.biggest, avoid, obscured.bottom, mini, origin,
                    miniSize: compactCard
                        ? _MiniCallCard.size
                        : widget.options.miniSize,
                    margin: compactCard ? 16 : widget.options.margin,
                    initialTop: compactCard ? 105 : null);
                final rect = windowRect(
                    dragSession == m.state.sessionId ? position : null);
                final full = m.state.hasWindow && !mini;
                final weakNotice = switch ((
                  m.state.media.localWeak,
                  m.state.media.remoteWeak
                )) {
                  (true, true) => '当前双方网络不佳',
                  (true, false) => '当前你的网络不佳',
                  (false, true) => '当前对方网络不佳',
                  _ => null,
                };
                return Stack(children: [
                  Positioned.fill(
                      child: ExcludeSemantics(
                          excluding: full,
                          child: ExcludeFocus(
                              excluding: full, child: widget.child))),
                  if (m.state.hasWindow)
                    Positioned.fromRect(
                      rect: rect,
                      child: Material(
                        key: ValueKey(m.state.sessionId),
                        elevation: compactCard ? 7.5 : 12,
                        animationDuration:
                            compactCard ? Duration.zero : kThemeChangeDuration,
                        color: widget.options.backgroundColor,
                        borderRadius: BorderRadius.circular(compactCard
                            ? 20
                            : (mini ? widget.options.miniRadius : 0)),
                        clipBehavior:
                            compactCard ? Clip.antiAlias : Clip.hardEdge,
                        child: Semantics(
                          container: true,
                          explicitChildNodes: true,
                          child: RotatedBox(
                            quarterTurns: rotated ? 1 : 0,
                            child: _CallPanel(
                              safe: rotated
                                  ? EdgeInsets.fromLTRB(safe.top, safe.right,
                                      safe.bottom, safe.left)
                                  : safe,
                              controller: m,
                              compactCard: compactCard,
                              options: widget.options,
                              onDrag: (delta) {
                                if (mini) {
                                  setState(() {
                                    final current = windowRect(
                                        dragSession == m.state.sessionId
                                            ? position
                                            : null);
                                    dragSession = m.state.sessionId;
                                    position =
                                        windowRect(current.topLeft + delta)
                                            .topLeft;
                                  });
                                }
                              },
                              onDragEnd: () {
                                if (mini) {
                                  final current = position ?? rect.topLeft;
                                  final room = math.max(
                                      0.0,
                                      size.maxWidth -
                                          avoid.horizontal -
                                          rect.width);
                                  final inset = compactCard
                                      ? math.min(16.0, room / 2)
                                      : 0.0;
                                  setState(() => position = Offset(
                                      current.dx < avoid.left + room / 2
                                          ? avoid.left + inset
                                          : avoid.left + room - inset,
                                      current.dy));
                                }
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (m.state.hasWindow && !mini)
                    Positioned.fill(
                        child: _CallSystemBars(
                            controller: m, padding: padding, rotated: rotated)),
                  if (m.state.hasWindow &&
                      m.state.phase != CallPhase.ending &&
                      weakNotice != null)
                    Positioned(
                        bottom: avoid.bottom + 28,
                        left: 16,
                        right: 16,
                        child: _CallToast(
                            key: ValueKey((m.state.sessionId, 'weak')),
                            localWeak: m.state.media.localWeak,
                            remoteWeak: m.state.media.remoteWeak,
                            message: weakNotice)),
                  if (!m.state.hasWindow &&
                      m.state.lastSummary?.error?.code ==
                          CallErrorCode.systemCallBusy)
                    Positioned(
                        bottom: avoid.bottom + 28,
                        left: 16,
                        right: 16,
                        child: _CallToast(
                          key: ValueKey(m.state.lastSummary!.context.sessionId),
                          message: CallException.systemCallBusyMessage,
                        )),
                ]);
              });
            }));
  }
}

class _CallToast extends StatefulWidget {
  const _CallToast(
      {super.key,
      required this.message,
      this.localWeak = false,
      this.remoteWeak = false});
  final bool localWeak, remoteWeak;
  final String message;
  @override
  State<_CallToast> createState() => _CallToastState();
}

class _CallToastState extends State<_CallToast> {
  Timer? _timer;
  bool _visible = true;
  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didUpdateWidget(_CallToast previous) {
    super.didUpdateWidget(previous);
    if (previous.localWeak == widget.localWeak &&
        previous.remoteWeak == widget.remoteWeak) {
      return;
    }
    _timer?.cancel();
    _visible = (widget.localWeak && !previous.localWeak) ||
        (widget.remoteWeak && !previous.remoteWeak);
    if (_visible) _startTimer();
  }

  void _startTimer() {
    _timer = Timer(
        const Duration(seconds: 3), () => setState(() => _visible = false));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !_visible
      ? const SizedBox.shrink()
      : IgnorePointer(
          child: Center(
              child: Semantics(
                  liveRegion: true,
                  child: Material(
                      color: const Color(0xEB252525),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 12),
                          child: Text(widget.message,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 15)))))));
}

// A sibling above the call sets both system-bar styles without replacing the
// video widgets when returning from the mini window.
class _CallSystemBars extends StatefulWidget {
  const _CallSystemBars(
      {required this.controller, required this.padding, required this.rotated});
  final VideoServiceController controller;
  final EdgeInsets padding;
  final bool rotated;
  @override
  State<_CallSystemBars> createState() => _CallSystemBarsState();
}

class _CallSystemBarsState extends State<_CallSystemBars> {
  SystemUiOverlayStyle? _previousIosStyle;

  // Removal happens before compositing, so an underlying AppBar can still
  // select its own current style in the very same frame.
  @override
  void deactivate() {
    final style = _previousIosStyle;
    if (style != null) SystemChrome.setSystemUIOverlayStyle(style);
    super.deactivate();
  }

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // The pinned Flutter SDK exposes its last platform style only via this
      // getter. An imperative host has no AnnotatedRegion to read on exit.
      // ignore: invalid_use_of_visible_for_testing_member
      _previousIosStyle = SystemChrome.latestStyle ??
          (WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                  Brightness.dark
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark);
    }
    widget.controller.setFlutterCallFullscreen(true);
  }

  @override
  void didUpdateWidget(_CallSystemBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.setFlutterCallFullscreen(false);
      widget.controller.setFlutterCallFullscreen(true);
    }
  }

  @override
  void dispose() {
    widget.controller.setFlutterCallFullscreen(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // In an in-app rotation the video gradient rotates too. The OS indicators
    // stay at the physical edges; side navigation can also occur in landscape.
    final padding = widget.padding;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarBrightness: Brightness.dark,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarContrastEnforced: false,
        systemStatusBarContrastEnforced: false,
      ),
      child: IgnorePointer(
          child: Stack(fit: StackFit.expand, children: [
        if (widget.rotated && padding.top > 0)
          _scrim(Alignment.topCenter, padding.top),
        if (widget.rotated && padding.bottom > 0)
          _scrim(Alignment.bottomCenter, padding.bottom),
        if (padding.left > 0) _scrim(Alignment.centerLeft, padding.left),
        if (padding.right > 0) _scrim(Alignment.centerRight, padding.right),
      ])),
    );
  }

  Widget _scrim(Alignment edge, double inset) {
    final side = edge.x != 0;
    final extent = inset + 8;
    return Align(
        alignment: edge,
        child: SizedBox(
          width: side ? extent : double.infinity,
          height: side ? double.infinity : extent,
          child: DecoratedBox(
              decoration: BoxDecoration(
                  gradient: LinearGradient(
            begin: edge,
            end: -edge,
            colors: const [Colors.black54, Colors.black54, Colors.transparent],
            stops: [0, inset / extent, 1],
          ))),
        ));
  }
}

class _CallPanel extends StatefulWidget {
  const _CallPanel(
      {required this.controller,
      required this.compactCard,
      required this.options,
      required this.safe,
      required this.onDrag,
      required this.onDragEnd});
  final VideoServiceController controller;
  final bool compactCard;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onDragEnd;
  final EdgeInsets safe;
  final CallWindowOptions options;

  @override
  State<_CallPanel> createState() => _CallPanelState();
}

class _CallPanelState extends State<_CallPanel> {
  bool qualityMenu = false;

  // The controller exposes failures through its state and the recovery notice.
  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on CallException {
      // The matching recovery action is presented by the notice.
    }
  }

  @override
  void didUpdateWidget(_CallPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final state = widget.controller.state;
    if (state.windowMode == CallWindowMode.mini ||
        !widget.controller.showsCallSurface ||
        !state.media.controlsReady ||
        state.controlBusy) {
      qualityMenu = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final options = widget.options;
    final state = controller.state;
    final mini = state.windowMode == CallWindowMode.mini;
    final waiting = !controller.showsCallSurface;
    final canControl = state.media.controlsReady && !state.controlBusy;
    final primary = controller.primaryVideo;
    final secondary =
        primary == VideoRole.local ? VideoRole.remote : VideoRole.local;
    final safe = widget.safe;
    final phase =
        options.phaseLabelBuilder?.call(state) ?? callPhaseLabel(state.phase);
    final endLabel = state.error?.recovery == CallRecovery.restartRequired
        ? '请重新启动 App'
        : state.error?.code == CallErrorCode.cleanupFailed
            ? '重试结束'
            : state.probe
                ? '结束测试'
                : waiting
                    ? '取消'
                    : '挂断';
    final canEnd = state.error?.recovery != CallRecovery.restartRequired &&
        (state.phase != CallPhase.ending ||
            state.error?.code == CallErrorCode.cleanupFailed);
    final waitLabel =
        state.phase == CallPhase.ending || state.phase == CallPhase.reconnecting
            ? phase
            : controller.queueLabel ??
                options.phaseLabelBuilder?.call(state) ??
                '等待坐席接听，请稍等…';
    final quality = switch (state.media.quality) {
      VideoQuality.sd => '标清',
      VideoQuality.hd => '高清',
      null => '清晰度',
    };
    Widget video(VideoRole role) => CustomerNativeView(
        key: ValueKey('${role.name}-video'),
        viewType: 'customer_rtc/video',
        parameters: {'role': role.name, 'probe': state.probe});
    return LayoutBuilder(builder: (context, bounds) {
      final availableHeight = math.max(0.0, bounds.maxHeight - safe.vertical);
      final small = availableHeight < 400;
      final avatarSize = small ? 52.0 : 100.0;
      final avatarShadow = _ServiceAvatar.shadowInset(avatarSize);
      final headerHeight = math.min(mini ? 38.0 : 60.0, availableHeight / 3);
      final bottom = mini
          ? 0.0
          : small
              ? safe.bottom + 4
              : math.max(safe.bottom, waiting ? 48.0 : 40.0);
      final headerTop = mini || small ? safe.top : math.max(44.0, safe.top);
      final cardSize = _MiniCallCard.size;
      final cardWidth = mini
          ? math.min(52.0, bounds.maxWidth * .24)
          : math.min(
              cardSize.width,
              math.max(
                  0.0,
                  math.min(
                      bounds.maxWidth - safe.horizontal - 16,
                      (bounds.maxHeight -
                              headerTop -
                              headerHeight -
                              1 -
                              bottom) *
                          cardSize.aspectRatio)));
      final subtitle = mini
          ? (waiting ? waitLabel : phase)
          : (state.probe ||
                  options.phaseLabelBuilder != null ||
                  state.phase == CallPhase.reconnecting ||
                  state.phase == CallPhase.ending
              ? phase
              : null);
      final compactRow =
          !mini && small && bounds.maxWidth - safe.horizontal >= 420;
      final control = _CallControl(
          label: endLabel,
          waitingCancel: waiting && !mini,
          icon: _CallGlyph.end,
          gradient: const LinearGradient(
              begin: Alignment(-.707, -1.177),
              end: Alignment(.707, 1.177),
              stops: [.17, .87],
              colors: [Color(0xE6FF5360), Color(0xFFFF3141)]),
          small: small,
          onTap: canEnd ? () => _run(controller.hangup) : null);
      Widget footer;
      if (mini) {
        footer = TextButton.icon(
            onPressed: canEnd ? () => _run(controller.hangup) : null,
            style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: const Color(0xFFAD2537)),
            icon: _CallIcon(_CallGlyph.end,
                color: canEnd ? Colors.white : Colors.white54),
            label: Text(endLabel));
      } else if (waiting) {
        footer = control;
      } else {
        footer = _controls(controller,
            small: small,
            landscape: bounds.maxWidth > bounds.maxHeight,
            compactRow: compactRow,
            endButton: control);
      }
      final message = widget.compactCard ? null : _notice(state);
      final retryToken = controller.canRefreshToken;
      final canRebind = state.media.bindingFailures.isNotEmpty && canControl;
      final notice = message == null
          ? const SizedBox.shrink()
          : _CallNotice(
              message: message,
              retryLabel: retryToken
                  ? '重试通话授权'
                  : canRebind
                      ? '恢复画面'
                      : null,
              onRetry: () => _run(retryToken
                  ? controller.refreshToken
                  : controller.retryVideoBinding));
      Positioned videoPosition(VideoRole role, Widget child, {Key? key}) {
        if (role == primary || widget.compactCard) {
          return Positioned.fill(key: key, child: child);
        }
        return Positioned(
            key: key,
            right: safe.right + (mini ? 6 : 16),
            top: mini ? null : headerTop + headerHeight + 1,
            bottom: mini ? 46 : null,
            width: cardWidth,
            height: cardWidth * (mini ? 1.55 : 1 / cardSize.aspectRatio),
            child: child);
      }

      Widget surface(VideoRole role) {
        final inset = role == secondary && !widget.compactCard;
        final full = !waiting && !mini;
        final timedInset =
            inset && full && controller.miniElapsedDuration != null;
        final remoteUnavailable = !state.probe &&
            role == VideoRole.remote &&
            !controller.miniRemoteVideo;
        // The role key and the path to the native view stay fixed as the two
        // sibling layers change paint order and bounds.
        return videoPosition(
            role,
            IgnorePointer(
                child: ClipRRect(
              borderRadius: BorderRadius.circular(inset ? (mini ? 7 : 20) : 0),
              child: Stack(fit: StackFit.expand, children: [
                Opacity(
                    opacity:
                        widget.compactCard && role == VideoRole.local ? 0 : 1,
                    child: video(role)),
                if (timedInset)
                  _PeerVideoCard(controller: controller, role: role)
                else if (!widget.compactCard && !waiting && remoteUnavailable)
                  if (inset)
                    const _AvatarPreview()
                  else
                    const DecoratedBox(
                        decoration: BoxDecoration(gradient: _agentCardGradient),
                        child: Center(child: _ServiceAvatar(size: 100)))
                else if (!widget.compactCard &&
                    !waiting &&
                    !state.probe &&
                    role == VideoRole.local &&
                    !state.media.cameraEnabled)
                  ColoredBox(
                      color: const Color(0xFF273434),
                      child: Center(
                          child:
                              _LocalAvatar(path: controller.localAvatarPath))),
                if (full && !inset)
                  const DecoratedBox(
                      decoration: BoxDecoration(
                          gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                        Color(0xB3000000),
                        Colors.transparent,
                        Colors.transparent,
                        Color(0xB3000000)
                      ],
                              stops: [
                        0,
                        .186,
                        .645,
                        1
                      ]))),
                if (inset && !mini && !timedInset)
                  const CustomPaint(foregroundPainter: _MiniCardBorder()),
              ]),
            )),
            key: ValueKey(role));
      }

      return Stack(fit: StackFit.expand, children: [
        surface(primary),
        surface(secondary),
        if (controller.canSwapVideo)
          videoPosition(
              secondary,
              Semantics(
                button: true,
                label: secondary == VideoRole.remote ? '切换到对方主画面' : '切换到本机主画面',
                onTap: controller.swapVideo,
                child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    excludeFromSemantics: true,
                    onTap: controller.swapVideo),
              )),
        if (waiting && !widget.compactCard)
          Positioned.fill(
              child: DecoratedBox(
                  decoration: BoxDecoration(
                      color: options.backgroundColor,
                      image: const DecorationImage(
                          image: AssetImage('assets/call_wait_background.jpg',
                              package: 'customer_video_service'),
                          fit: BoxFit.cover)))),
        if (widget.compactCard)
          Positioned.fill(
              child: _MiniCallCard(
                  controller: controller,
                  onRestore: controller.restore,
                  onDrag: widget.onDrag,
                  onDragEnd: widget.onDragEnd))
        else if (mini)
          Positioned.fill(
              child: GestureDetector(
                  behavior: HitTestBehavior.opaque, onTap: controller.restore)),
        if (waiting && !mini)
          Positioned(
              left: safe.left + 20,
              right: safe.right + 20,
              // MasterGo places the avatar at y=250 on a 375×812 canvas.
              // Anchor its top edge so longer queue text never shifts the avatar.
              top: math.max(headerTop + headerHeight,
                  bounds.maxHeight * 250 / 812 - avatarShadow),
              bottom: math.max(
                  safe.bottom,
                  math.min(
                      bounds.maxHeight * .36, bottom + (small ? 62 : 100))),
              child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(height: avatarShadow),
                _ServiceAvatar(size: avatarSize),
                SizedBox(height: small ? 10 : 20),
                ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 187.5),
                    child: Text(waitLabel,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: options.foregroundColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w400,
                            height: 18 / 13))),
              ]))),
        if (!widget.compactCard)
          Positioned(
              top: headerTop,
              left: safe.left,
              right: safe.right,
              height: headerHeight,
              child: mini
                  ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (d) => widget.onDrag(d.delta),
                      onPanEnd: (_) => widget.onDragEnd(),
                      child: ColoredBox(
                          color: Colors.black54,
                          child: Row(children: [
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(subtitle ?? phase,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: options.foregroundColor,
                                        fontSize: 12))),
                            Tooltip(
                                message: '恢复全屏',
                                child: TextButton(
                                    onPressed: controller.restore,
                                    style: TextButton.styleFrom(
                                        foregroundColor:
                                            options.foregroundColor,
                                        minimumSize: const Size(44, 38),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6)),
                                    child: const Text('全屏'))),
                          ])))
                  : Stack(children: [
                      if (!waiting)
                        Align(
                            alignment: Alignment.topCenter,
                            child: Padding(
                                padding: const EdgeInsets.only(top: 10),
                                child: subtitle != null
                                    ? Text(subtitle,
                                        style: TextStyle(
                                            color: options.foregroundColor,
                                            fontSize: 13))
                                    : _CallClock(
                                        controller: controller,
                                        color: options.foregroundColor))),
                      Align(
                          alignment: Alignment.topLeft,
                          child: SizedBox(
                              height: 44,
                              child: IconButton(
                                  tooltip: '缩小窗口',
                                  onPressed: controller.minimize,
                                  color: options.foregroundColor,
                                  icon: _CallIcon(
                                      waiting
                                          ? _CallGlyph.minimizeWait
                                          : _CallGlyph.minimize,
                                      color: options.foregroundColor)))),
                      if (!waiting && !state.probe)
                        Align(
                            alignment: Alignment.topRight,
                            child: SizedBox(
                                height: 44,
                                child: TextButton(
                                    onPressed: canControl
                                        ? () => setState(
                                            () => qualityMenu = !qualityMenu)
                                        : null,
                                    style: TextButton.styleFrom(
                                        foregroundColor:
                                            options.foregroundColor,
                                        disabledForegroundColor:
                                            Colors.white54),
                                    child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(quality,
                                              style: const TextStyle(
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w400,
                                                  height: 21 / 15)),
                                          const SizedBox(width: 4),
                                          _CallIcon(_CallGlyph.qualityArrow,
                                              color: canControl
                                                  ? options.foregroundColor
                                                  : Colors.white54)
                                        ])))),
                    ])),
        if (!widget.compactCard &&
            (message != null || options.noticeBuilder != null))
          Positioned(
              left: safe.left + 8,
              right: safe.right + 8,
              top: headerTop + headerHeight + 4,
              child: Center(
                  child: options.noticeBuilder
                          ?.call(context, controller, notice) ??
                      notice)),
        if (!widget.compactCard)
          Positioned(
              left: safe.left,
              right: safe.right,
              bottom: bottom,
              child: ConstrainedBox(
                  constraints: BoxConstraints(
                      maxHeight: math.max(
                          0.0,
                          bounds.maxHeight -
                              headerTop -
                              headerHeight -
                              bottom)),
                  child: SingleChildScrollView(
                      child: Center(
                          child: options.controlsBuilder
                                  ?.call(context, controller, footer) ??
                              footer)))),
        if (qualityMenu && !waiting && !mini && !state.probe) ...[
          Positioned.fill(
              child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => qualityMenu = false),
                  excludeFromSemantics: true)),
          Positioned(
              top: math.max(
                  safe.top,
                  math.min(headerTop + headerHeight,
                      bounds.maxHeight - safe.bottom - 96)),
              right: safe.right + 12,
              child: _QualityMenu(
                  selected: state.media.quality,
                  onSelect: (value) {
                    setState(() => qualityMenu = false);
                    if (canControl && state.media.quality != value) {
                      _run(() => controller.setVideoQuality(value));
                    }
                  })),
        ],
      ]);
    });
  }

  Widget _controls(VideoServiceController controller,
      {required bool small,
      required bool landscape,
      required bool compactRow,
      required Widget endButton}) {
    final media = controller.state.media;
    final canControl = media.controlsReady && !controller.state.controlBusy;
    final secondRow = [
      _CallControl(
          label: landscape ? '切换竖屏' : '切换横屏',
          icon: _CallGlyph.rotate,
          small: small,
          onTap: controller.canToggleOrientation
              ? () => _run(controller.toggleCallOrientation)
              : null),
      endButton,
      _CallControl(
          label: '翻转摄像头',
          icon: _CallGlyph.flip,
          small: small,
          onTap: canControl ? () => _run(controller.switchCamera) : null),
    ];
    final firstRow = [
      _CallControl(
          label: media.muted ? '麦克风已关' : '麦克风已开',
          icon: _CallGlyph.mic,
          active: !media.muted,
          small: small,
          onTap: canControl
              ? () => _run(() => controller.setMuted(!media.muted))
              : null),
      _CallControl(
          label: switch (media.audioRoute) {
            AudioRoute.wired => '有线耳机',
            AudioRoute.bluetooth => '蓝牙设备',
            AudioRoute.earpiece => '听筒已开',
            AudioRoute.speaker => '扬声器已开',
            _ => controller.speakerActive ? '扬声器已开' : '扬声器已关',
          },
          icon: _CallGlyph.speaker,
          active: controller.speakerActive,
          small: small,
          onTap: canControl ? () => _run(controller.toggleSpeaker) : null),
      _CallControl(
          label: media.cameraEnabled ? '摄像头已开' : '摄像头已关',
          icon: _CallGlyph.camera,
          active: media.cameraEnabled,
          small: small,
          onTap: canControl
              ? () =>
                  _run(() => controller.setCameraEnabled(!media.cameraEnabled))
              : null),
    ];
    Widget row(List<Widget> items) =>
        Row(children: [for (final item in items) Expanded(child: item)]);
    return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: compactRow ? 680 : 327),
        child: compactRow
            ? row([...firstRow, ...secondRow])
            : Column(mainAxisSize: MainAxisSize.min, children: [
                row(firstRow),
                SizedBox(height: small ? 4 : 19),
                row(secondRow)
              ]));
  }

  String? _notice(CallState state) {
    if (state.error?.recovery == CallRecovery.restartRequired) {
      return '通话资源释放失败，请重新启动 App';
    }
    if (state.error?.code == CallErrorCode.cleanupFailed) {
      return '通话资源尚未释放，请重试结束';
    }
    if (widget.controller.canRefreshToken ||
        state.error?.code == CallErrorCode.tokenRefreshFailed) {
      return '通话授权更新失败';
    }
    if (state.media.bindingFailures.isNotEmpty) return '画面暂时不可用，可重试恢复';
    if (state.error != null) return '操作失败（${state.error!.code.name}）';
    final remoteTrack = state.media.trackStates[MediaTrack.remoteVideo];
    if (remoteTrack?.activity == TrackActivity.stopped) return '对方视频已暂停';
    if (remoteTrack?.activity == TrackActivity.failed) return '对方视频暂不可用';
    if (state.media.trackStates[MediaTrack.localVideo]?.activity ==
        TrackActivity.failed) {
      return '摄像头采集失败';
    }
    if (state.media.trackStates[MediaTrack.localAudio]?.activity ==
        TrackActivity.failed) {
      return '麦克风采集失败';
    }
    if (state.needsToken) {
      return widget.controller.tokenProvider == null ? '通话授权需要更新' : '正在更新通话授权';
    }
    return null;
  }
}

class VideoServiceBackScope extends StatelessWidget {
  const VideoServiceBackScope(
      {super.key, required this.controller, required this.child});
  final VideoServiceController controller;
  final Widget child;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) => PopScope(
          canPop: !controller.state.hasWindow ||
              controller.state.windowMode == CallWindowMode.mini,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) controller.minimize();
          },
          child: child));
}
