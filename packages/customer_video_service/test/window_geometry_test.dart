import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:customer_video_service/src/call/window_geometry.dart';

void main() {
  test('mini window stays inside safe bounds after drag and keyboard appears',
      () {
    final rect = callWindowRect(
        const Size(390, 844),
        const EdgeInsets.only(top: 47, bottom: 34),
        320,
        true,
        const Offset(900, 900));
    expect(rect.width, greaterThan(0));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(390));
    expect(rect.top, greaterThanOrEqualTo(47));
    expect(rect.bottom, lessThanOrEqualTo(524));
  });
  test('small landscape screen never yields negative sizes', () {
    final rect = callWindowRect(const Size(240, 160), EdgeInsets.zero, 70, true,
        const Offset(-50, -20));
    expect(rect.left, 0);
    expect(rect.top, 0);
    expect(rect.width, greaterThan(0));
    expect(rect.height, greaterThan(0));
    expect(rect.bottom, lessThanOrEqualTo(90));
  });
  test('full screen keeps its background behind system bars and the keyboard',
      () {
    final rect = callWindowRect(const Size(400, 800),
        const EdgeInsets.only(top: 40, bottom: 20), 300, false, null);
    expect(rect, const Rect.fromLTWH(0, 0, 400, 800));
  });
}
