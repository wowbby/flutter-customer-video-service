import 'dart:math' as math;
import 'package:flutter/painting.dart';

Rect callWindowRect(
    Size screen, EdgeInsets safe, double keyboard, bool mini, Offset? position,
    {Size miniSize = const Size(190, 250),
    double margin = 12,
    double? initialTop}) {
  if (!mini) return Offset.zero & screen;
  final left = safe.left;
  final top = safe.top;
  final width = math.max(0.0, screen.width - safe.horizontal);
  final height =
      math.max(0.0, screen.height - top - math.max(safe.bottom, keyboard));
  final w = math.min(miniSize.width, width);
  final h = math.min(miniSize.height, height);
  return Rect.fromLTWH(
      (position?.dx ?? left + width - w - margin).clamp(left, left + width - w),
      (position?.dy ?? initialTop ?? top + 80).clamp(top, top + height - h),
      w,
      h);
}
