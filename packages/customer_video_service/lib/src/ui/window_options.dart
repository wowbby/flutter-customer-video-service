import 'package:flutter/widgets.dart';
import '../controller.dart';
import '../models.dart';

class CallWindowOptions {
  const CallWindowOptions(
      {this.miniSize = const Size(190, 250),
      this.margin = 12,
      this.miniRadius = 16,
      this.backgroundColor = const Color(0xFF1D2626),
      this.foregroundColor = const Color(0xFFFFFFFF),
      this.phaseLabelBuilder,
      this.noticeBuilder,
      this.controlsBuilder})
      : assert(margin >= 0),
        assert(miniRadius >= 0);
  void validate() {
    if (!miniSize.width.isFinite ||
        !miniSize.height.isFinite ||
        miniSize.width <= 0 ||
        miniSize.height <= 0 ||
        !margin.isFinite ||
        margin < 0 ||
        !miniRadius.isFinite ||
        miniRadius < 0) {
      throw ArgumentError(
          'Window dimensions and insets must be finite and nonnegative');
    }
  }

  final Size miniSize;
  final double margin, miniRadius;
  final Color backgroundColor, foregroundColor;
  final String Function(CallState)? phaseLabelBuilder;
  final Widget Function(BuildContext, VideoServiceController, Widget)?
      noticeBuilder;
  final Widget Function(BuildContext, VideoServiceController, Widget)?
      controlsBuilder;
}
