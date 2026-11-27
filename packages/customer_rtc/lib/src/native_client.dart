import 'package:flutter/services.dart';

abstract interface class RtcTransport {
  Stream<Map<String, dynamic>> get events;
  Future<Object?> invoke(String method, Map<String, Object?> arguments);
}

enum SystemCallState { unknown, idle, ringing, active }

/// A session-scoped read also observes changes until leave or cancellation.
/// A read without an ID only samples the current system state.
abstract interface class SystemCallMonitor {
  Future<SystemCallState> getSystemCallState({String? sessionId});
  Future<void> endSystemCallObservation(String sessionId);
}

class NativeRtcClient implements RtcTransport, SystemCallMonitor {
  static const _methods = MethodChannel('customer_rtc');
  static const _events = EventChannel('customer_rtc/events');
  static final Stream<Map<String, dynamic>> _stream = _events
      .receiveBroadcastStream()
      .map((event) => Map<String, dynamic>.from(event as Map));

  @override
  Stream<Map<String, dynamic>> get events => _stream;

  @override
  Future<SystemCallState> getSystemCallState({String? sessionId}) async {
    final result = await invoke('getSystemCallState', {
      if (sessionId != null) 'sessionId': sessionId,
    });
    return SystemCallState.values.firstWhere((state) => state.name == result,
        orElse: () => SystemCallState.unknown);
  }

  @override
  Future<void> endSystemCallObservation(String sessionId) async {
    await invoke('endSystemCallObservation', {'sessionId': sessionId});
  }

  @override
  Future<Object?> invoke(String method, Map<String, Object?> arguments) =>
      _methods.invokeMethod<Object?>(method, arguments);
}
