import 'dart:async';
import 'dart:convert';
import 'controller.dart';
import 'models.dart';

typedef H5Sender = FutureOr<void> Function(Map<String, Object?> message);

/// Protocol only. The container must validate main-frame origin before forwarding.
class CustomerH5Bridge {
  CustomerH5Bridge({required this.controller, this.onOpenBusiness}) {
    controller.addListener(_publish);
  }
  final VideoServiceController controller;
  final FutureOr<void> Function()? onOpenBusiness;
  final Set<H5Binding> _bindings = {};
  bool _disposed = false;
  H5Binding attach(
      {required H5Sender send, CallRequest Function()? requestForCall}) {
    if (_disposed) throw StateError('Bridge disposed');
    final binding = H5Binding._(this, send, requestForCall);
    _bindings.add(binding);
    return binding;
  }

  void _publish() {
    for (final binding in _bindings.toList()) {
      unawaited(binding._publish());
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    controller.removeListener(_publish);
    for (final binding in _bindings.toList()) {
      binding.dispose();
    }
  }
}

/// One trusted document generation. Dispose/re-attach whenever the page reloads.
class H5Binding {
  H5Binding._(this._bridge, this._sendMessage, this._requestForCall);
  final CallRequest Function()? _requestForCall;
  final CustomerH5Bridge _bridge;
  final H5Sender _sendMessage;
  final Map<String, _Request> _requests = {};
  bool _disposed = false, _ready = false;
  Future<void> ready() async {
    if (_disposed) return;
    _ready = true;
    await _publish();
  }

  Future<void> _publish() =>
      _send({'kind': 'state', 'state': _bridge.controller.state.toBridgeMap()});
  Future<void> _send(Map<String, Object?> message) async {
    if (_disposed || !_ready || _bridge._disposed) return;
    try {
      await _sendMessage(message);
    } catch (_) {/* Container may already be gone. */}
  }

  Future<void> receive(String message) async {
    if (_disposed || !_ready || _bridge._disposed) return;
    await _send(await _handle(message));
  }

  Map<String, Object?> _error(String? id, String code) => {
        'kind': 'response',
        'requestId': id,
        'ok': false,
        'error': code,
        if (code == CallErrorCode.systemCallBusy.name)
          'message': CallException.systemCallBusyMessage
      };
  Future<Map<String, Object?>> _handle(String message) async {
    String? id;
    try {
      if (message.length > 8192) return _error(null, 'invalidRequest');
      final parsed = jsonDecode(message);
      if (parsed is! Map<String, dynamic> ||
          parsed['version'] != 1 ||
          parsed['requestId'] is! String ||
          parsed['action'] is! String ||
          parsed['params'] is! Map<String, dynamic>) {
        return _error(null, 'invalidRequest');
      }
      id = parsed['requestId'] as String;
      if (id.isEmpty || id.length > 128) return _error(null, 'invalidRequest');
      final existing = _requests[id];
      if (existing != null) {
        return existing.body == message
            ? existing.future
            : _error(id, 'requestConflict');
      }
      while (_requests.length >= 128) {
        String? completed;
        for (final entry in _requests.entries) {
          if (entry.value.done) {
            completed = entry.key;
            break;
          }
        }
        if (completed == null) return _error(id, 'tooManyRequests');
        _requests.remove(completed);
      }
      final item = _Request(message);
      _requests[id] = item;
      item.future = _execute(parsed['action'] as String,
              parsed['params'] as Map<String, dynamic>, id)
          .whenComplete(() => item.done = true);
      return item.future;
    } on FormatException {
      return _error(id, 'invalidRequest');
    }
  }

  Future<Map<String, Object?>> _execute(
      String action, Map<String, dynamic> params, String id) async {
    final controller = _bridge.controller;
    try {
      CallStartResult? startResult;
      switch (action) {
        case 'startProbe':
          await controller.startProbe();
        case 'beginWaiting':
          final request = _requestForCall?.call() ?? const CallRequest();
          if (_disposed) return _error(id, 'staleDocument');
          await controller.beginWaiting(request: request);
        case 'startRtc':
          // Web params cannot inject host metadata or business acceptance.
          final request = _requestForCall?.call() ?? const CallRequest();
          if (_disposed) return _error(id, 'staleDocument');
          startResult = await controller.startCall(request: request);
        case 'getState':
          break;
        case 'hangup':
        case 'minimize':
        case 'restore':
          if (controller.state.sessionId == null ||
              params['sessionId'] != controller.state.sessionId) {
            return _error(id, 'staleSession');
          }
          if (action == 'hangup') {
            await controller.hangup();
          } else if (action == 'minimize') {
            controller.minimize();
          } else {
            controller.restore();
          }
        case 'openBusiness':
          final open = _bridge.onOpenBusiness;
          if (open == null) return _error(id, 'unsupported');
          controller.minimize();
          await open();
        default:
          return _error(id, 'unknownAction');
      }
      return {
        'kind': 'response',
        'requestId': id,
        'ok': true,
        'result': controller.state.toBridgeMap(),
        // A delayed start may resolve after redial. Keep its original identity
        // separate from the latest snapshot in the existing v1 result field.
        if (startResult != null)
          'startResult': {
            'sessionId': startResult.sessionId,
            'status': startResult.status.name,
          },
      };
    } on CallException catch (e) {
      return _error(id, e.code.name);
    } catch (_) {
      return _error(id, 'operationFailed');
    }
  }

  void dispose() {
    _disposed = true;
    _ready = false;
    _requests.clear();
    _bridge._bindings.remove(this);
  }
}

class _Request {
  _Request(this.body);
  final String body;
  bool done = false;
  late Future<Map<String, Object?>> future;
}
