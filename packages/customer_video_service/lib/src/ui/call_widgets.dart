part of 'call_window.dart';

const _agentCardGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0xFF70C2BE), Color(0xFF53908D)],
);

class _MiniCallCard extends StatelessWidget {
  const _MiniCallCard({
    required this.controller,
    required this.onRestore,
    required this.onDrag,
    required this.onDragEnd,
  });
  static const size = Size(84, 150);
  final VideoServiceController controller;
  final VoidCallback onRestore, onDragEnd;
  final ValueChanged<Offset> onDrag;

  @override
  Widget build(BuildContext context) {
    final label = controller.miniElapsedDuration != null
        ? '通话中'
        : (controller.state.probe ? '无媒体测试' : '等待接听');
    return Semantics(
      button: true,
      label: label,
      hint: '恢复全屏',
      onTap: onRestore,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: onRestore,
        onPanUpdate: (event) => onDrag(event.delta),
        onPanEnd: (_) => onDragEnd(),
        child: _PeerVideoCard(controller: controller),
      ),
    );
  }
}

/// The minimized call and the remote inset in the full call use the same artwork.
class _PeerVideoCard extends StatelessWidget {
  const _PeerVideoCard(
      {required this.controller, this.role = VideoRole.remote});
  final VideoServiceController controller;
  final VideoRole role;
  @override
  Widget build(BuildContext context) {
    final timed = controller.miniElapsedDuration != null;
    final waiting = controller.awaitingAnswer;
    final local = role == VideoRole.local;
    final showVideo = timed &&
        (local
            ? controller.state.media.cameraEnabled
            : controller.miniRemoteVideo);
    return CustomPaint(
      foregroundPainter: const _MiniCardBorder(),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: local && !showVideo ? const Color(0xFF273434) : null,
          gradient: showVideo || local
              ? null
              : waiting
                  ? const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF222D2D), Color(0xFF273434)],
                      stops: [.03, .97])
                  : _agentCardGradient,
        ),
        child: Padding(
          padding: const EdgeInsets.all(1.5),
          child: ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(18.5)),
            child: Stack(fit: StackFit.expand, children: [
              if (!showVideo && local)
                Center(child: _LocalAvatar(path: controller.localAvatarPath))
              else if (!showVideo)
                const FractionallySizedBox(
                  alignment: Alignment(0, -22 / 89),
                  widthFactor: 58 / 81,
                  heightFactor: 58 / 147,
                  child: FittedBox(child: _ServiceAvatar.mini()),
                ),
              Align(
                alignment: Alignment.bottomCenter,
                child: FractionallySizedBox(
                  widthFactor: 1,
                  heightFactor: 28 / 147,
                  child: ColoredBox(
                    color: waiting
                        ? const Color(0x66455353)
                        : const Color(0x6609403D),
                    child: Center(
                      child: timed
                          ? _CallClock(
                              controller: controller,
                              color: Colors.white,
                              onCard: true)
                          : FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                  controller.state.probe ? '无媒体测试' : '等待接听',
                                  maxLines: 1,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500))),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// Draw only the rim so the native remote canvas remains visible in the center.
class _MiniCardBorder extends CustomPainter {
  const _MiniCardBorder();
  @override
  void paint(Canvas canvas, Size size) {
    if (size.shortestSide <= 1.5) return;
    final bounds = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xB3FFFFFF), Color(0xCCFFFFFF)]).createShader(bounds);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            bounds.deflate(.75), const Radius.circular(19.25)),
        paint);
  }

  @override
  bool shouldRepaint(_MiniCardBorder oldDelegate) => false;
}

class _LocalAvatar extends StatelessWidget {
  const _LocalAvatar({required this.path});
  final String? path;

  @override
  Widget build(BuildContext context) {
    const fallback = ColoredBox(
        color: Color(0xFF48605F),
        child: Icon(Icons.person, color: Colors.white, size: 34));
    final filePath = path;
    return Semantics(
        label: '用户头像',
        image: true,
        child: SizedBox.square(
            dimension: 58,
            child: ClipOval(
                child: filePath == null
                    ? fallback
                    : Image.file(File(filePath),
                        fit: BoxFit.cover,
                        cacheWidth: 192,
                        excludeFromSemantics: true,
                        errorBuilder: (_, __, ___) => fallback))));
  }
}

class _ServiceAvatar extends StatelessWidget {
  const _ServiceAvatar({required this.size}) : _mini = false;
  const _ServiceAvatar.mini()
      : size = 58,
        _mini = true;
  final double size;
  final bool _mini;

  // The MasterGo export includes a soft shadow around its 200 px avatar.
  static const double exportScale = 259 / 200;
  static double shadowInset(double size) => (exportScale - 1) * size / 2;
  @override
  Widget build(BuildContext context) {
    // In the 259px export the opaque face is 180px wide and sits above center.
    final pixels = _mini ? size * 259 / 180 : size * exportScale;
    final image = Image.asset('assets/service_avatar.png',
        package: 'customer_video_service',
        fit: BoxFit.contain,
        excludeFromSemantics: true);
    return SizedBox.square(
        dimension: size,
        child: OverflowBox(
            minWidth: pixels,
            maxWidth: pixels,
            minHeight: pixels,
            maxHeight: pixels,
            child: _mini
                ? Transform.translate(
                    offset: Offset(0, 15.5 * size / 180), child: image)
                : image));
  }
}

class _AvatarPreview extends StatelessWidget {
  const _AvatarPreview();

  @override
  Widget build(BuildContext context) => DecoratedBox(
      decoration: const BoxDecoration(gradient: _agentCardGradient),
      child: LayoutBuilder(
          builder: (context, size) => Stack(children: [
                Positioned(
                    left: size.maxWidth * 12.86 / 84,
                    top: size.maxHeight * 33.76 / 150,
                    child: _ServiceAvatar(size: size.maxWidth * 58 / 84)),
              ])));
}

enum _CallGlyph {
  mic,
  speaker,
  camera,
  rotate,
  end,
  flip,
  minimize,
  minimizeWait,
  qualityArrow
}

class _CallIcon extends StatelessWidget {
  const _CallIcon(this.glyph, {required this.color});
  final _CallGlyph glyph;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final name = switch (glyph) {
      _CallGlyph.qualityArrow => 'quality_arrow',
      _CallGlyph.minimizeWait => 'minimize_wait',
      _ => glyph.name,
    };
    final size = switch (glyph) {
      _CallGlyph.qualityArrow => 9.0,
      _CallGlyph.minimize || _CallGlyph.minimizeWait => 24.0,
      _ => 27.5,
    };
    return Image.asset('assets/call_icons/call_$name.png',
        package: 'customer_video_service',
        width: size,
        height: size,
        fit: BoxFit.contain,
        color: color,
        colorBlendMode: BlendMode.srcIn,
        excludeFromSemantics: true);
  }
}

class _CallControl extends StatelessWidget {
  const _CallControl(
      {required this.label,
      required this.icon,
      required this.onTap,
      required this.small,
      this.active = false,
      this.waitingCancel = false,
      this.gradient});
  final String label;
  final _CallGlyph icon;
  final VoidCallback? onTap;
  final bool small, active, waitingCancel;
  final Gradient? gradient;

  @override
  Widget build(BuildContext context) {
    final diameter = small
        ? 40.0
        : waitingCancel
            ? 65.0
            : 55.0;
    return Semantics(
        button: true,
        onTap: onTap,
        enabled: onTap != null,
        label: label,
        child: ExcludeSemantics(
            child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                          width: diameter,
                          height: diameter,
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: onTap == null ? null : gradient,
                              color: onTap == null
                                  ? Colors.white24
                                  : gradient != null
                                      ? null
                                      : active
                                          ? const Color(0xF0FFFFFF)
                                          : const Color(0x4DFFFFFF)),
                          child: Center(
                              child: _CallIcon(icon,
                                  color: onTap == null
                                      ? Colors.white60
                                      : active
                                          ? const Color(0xFF151B1B)
                                          : Colors.white))),
                      SizedBox(height: waitingCancel && !small ? 10 : 5),
                      Text(label,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color:
                                  onTap == null ? Colors.white60 : Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                              height: 18 / 13)),
                    ])))));
  }
}

class _CallNotice extends StatelessWidget {
  const _CallNotice(
      {required this.message, required this.retryLabel, required this.onRetry});
  final String message;
  final String? retryLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Semantics(
      liveRegion: true,
      child: DecoratedBox(
          decoration: BoxDecoration(
              color: const Color(0xE63B2C20),
              borderRadius: BorderRadius.circular(12)),
          child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(message,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 12)),
                    if (retryLabel != null)
                      TextButton(
                          onPressed: onRetry,
                          style: TextButton.styleFrom(
                              foregroundColor: Colors.white),
                          child: Text(retryLabel!))
                  ]))));
}

/// Only the clock repaints once a second. Its source is the session's monotonic
/// stopwatch, so minimizing, rotation and moving between hosts do not reset it.
class _CallClock extends StatefulWidget {
  const _CallClock(
      {required this.controller, required this.color, this.onCard = false});
  final bool onCard;
  final VideoServiceController controller;
  final Color color;
  @override
  State<_CallClock> createState() => _CallClockState();
}

class _CallClockState extends State<_CallClock> {
  Timer? timer;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_CallClock oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  Duration? get _elapsed => widget.onCard
      ? widget.controller.miniElapsedDuration
      : widget.controller.connectedDuration;

  void _sync() {
    timer?.cancel();
    final elapsed = _elapsed;
    if (elapsed == null || widget.controller.state.phase == CallPhase.ending) {
      return;
    }
    // Align to the session clock even when this widget mounts mid-second.
    final remainder = elapsed.inMicroseconds % Duration.microsecondsPerSecond;
    timer = Timer(
        Duration(microseconds: Duration.microsecondsPerSecond - remainder), () {
      setState(() {});
      _sync();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = _elapsed;
    final style = TextStyle(color: widget.color, fontSize: 13);
    if (elapsed == null) {
      return Text(callPhaseLabel(widget.controller.state.phase), style: style);
    }
    String two(int n) => n.toString().padLeft(2, '0');
    final hours = elapsed.inHours;
    final time =
        '${hours > 0 ? '${two(hours)}:' : ''}${two(elapsed.inMinutes.remainder(60))}:${two(elapsed.inSeconds.remainder(60))}';
    if (widget.onCard) {
      return ExcludeSemantics(
          child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(time,
                  style: style.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      fontFeatures: const [FontFeature.tabularFigures()]))));
    }
    return FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
              width: 169,
              height: 24,
              child: Center(
                  child: Text(time,
                      style: style.copyWith(
                          fontSize: 17,
                          height: 24 / 17,
                          fontWeight: FontWeight.w500,
                          fontFeatures: const [
                            FontFeature.tabularFigures()
                          ])))),
          const SizedBox(height: 2),
          SizedBox(
              width: 169,
              height: 24,
              child: Center(
                  child: Text('通话时长',
                      style: style.copyWith(
                          fontSize: 13,
                          height: 18 / 13,
                          fontWeight: FontWeight.w400)))),
        ]));
  }
}

class _QualityMenu extends StatelessWidget {
  const _QualityMenu({required this.selected, required this.onSelect});
  final VideoQuality? selected;
  final ValueChanged<VideoQuality> onSelect;

  @override
  Widget build(BuildContext context) => Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(16),
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final value in VideoQuality.values)
          Semantics(
              selected: value == selected,
              button: true,
              child: InkWell(
                  onTap: () => onSelect(value),
                  child: SizedBox(
                      width: 120,
                      height: 48,
                      child: Center(
                          child: Text(value == VideoQuality.hd ? '高清' : '标清',
                              style: TextStyle(
                                  fontSize: 14,
                                  color: value == selected
                                      ? const Color(0xFF008781)
                                      : const Color(0xFF22292A),
                                  fontWeight: value == selected
                                      ? FontWeight.w600
                                      : FontWeight.w400)))))),
      ]));
}
