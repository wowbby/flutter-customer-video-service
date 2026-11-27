import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The same stateful native view remains mounted when its Flutter bounds change.
class CustomerNativeView extends StatelessWidget {
  const CustomerNativeView(
      {super.key,
      required this.viewType,
      required this.parameters,
      this.onCreated,
      this.interactive = false});
  final String viewType;
  final Map<String, Object?> parameters;
  final ValueChanged<int>? onCreated;
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final gestures = <Factory<OneSequenceGestureRecognizer>>{
      if (interactive)
        Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
    };
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidView(
            viewType: viewType,
            creationParams: parameters,
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: onCreated,
            gestureRecognizers: gestures);
      case TargetPlatform.iOS:
        return UiKitView(
            viewType: viewType,
            creationParams: parameters,
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: onCreated,
            gestureRecognizers: gestures);
      case TargetPlatform.ohos:
        return OhosView(
            viewType: viewType,
            creationParams: parameters,
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: onCreated,
            gestureRecognizers: gestures);
      default:
        return const Center(child: Text('原生窗口仅支持 Android、iOS、鸿蒙'));
    }
  }
}
