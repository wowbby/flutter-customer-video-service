import 'dart:async';
import 'package:customer_rtc/customer_rtc.dart';
import 'package:flutter/widgets.dart';
import 'h5_bridge.dart';
import 'models.dart';

/// Optional bundled-HTML container. Custom hosts use CustomerH5Bridge directly.
/// To reload the document, replace this widget's Key (the call remains alive).
class CustomerServiceWebView extends StatefulWidget {
  const CustomerServiceWebView(
      {super.key,
      required this.bridge,
      required this.html,
      this.requestForCall});
  final CustomerH5Bridge bridge;
  final String html;
  final CallRequest Function()? requestForCall;
  @override
  State<CustomerServiceWebView> createState() => _CustomerServiceWebViewState();
}

class _CustomerServiceWebViewState extends State<CustomerServiceWebView> {
  final _native = NativeWebClient();
  late final StreamSubscription<NativeWebEvent> _subscription;
  final Set<int> _earlyReady = {};
  int? _viewId;
  bool _documentReady = false;
  H5Binding? _binding;
  @override
  void initState() {
    super.initState();
    _subscription = _native.events.listen((event) {
      if (event.type == NativeWebEventType.ready && _viewId == null) {
        _earlyReady.add(event.viewId);
        return;
      }
      if (event.viewId != _viewId) return;
      final binding = _binding;
      if (binding == null) return;
      if (event.type == NativeWebEventType.ready) {
        _documentReady = true;
        unawaited(binding.ready());
      } else {
        unawaited(binding.receive(event.message!));
      }
    }, onError: (Object _) {});
  }

  void _created(int id) {
    if (!mounted) return;
    _viewId = id;
    _binding?.dispose();
    _binding = widget.bridge.attach(
        requestForCall: () =>
            widget.requestForCall?.call() ?? const CallRequest(),
        send: (message) => _native.reply(id, message));
    _documentReady = _earlyReady.contains(id);
    if (_documentReady) unawaited(_binding!.ready());
    _earlyReady.clear();
  }

  @override
  void didUpdateWidget(CustomerServiceWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html) {
      _binding?.dispose();
      _binding = null;
      _viewId = null;
      _documentReady = false;
      _earlyReady.clear();
      return;
    }
    if (oldWidget.bridge != widget.bridge) {
      final id = _viewId;
      _binding?.dispose();
      if (id != null) {
        _binding = widget.bridge.attach(
            requestForCall: () =>
                widget.requestForCall?.call() ?? const CallRequest(),
            send: (message) => _native.reply(id, message));
        if (_documentReady) unawaited(_binding!.ready());
      }
    }
  }

  @override
  Widget build(BuildContext context) => CustomerNativeView(
      key: ValueKey(widget.html),
      viewType: 'customer_rtc/web',
      parameters: {'html': widget.html},
      interactive: true,
      onCreated: _created);
  @override
  void dispose() {
    _binding?.dispose();
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
