import 'dart:convert';
import 'native_client.dart';

enum NativeWebEventType { ready, message }

class NativeWebEvent {
  const NativeWebEvent(this.viewId, this.type, this.message);
  final int viewId;
  final NativeWebEventType type;
  final String? message;
}

/// Default native container adapter; shares the RTC client's single event source.
class NativeWebClient {
  final NativeRtcClient _client = NativeRtcClient();
  Stream<NativeWebEvent> get events => _client.events
      .where((e) =>
          e['viewId'] is int &&
          (e['type'] == 'webReady' ||
              (e['type'] == 'bridge' && e['message'] is String)))
      .map((e) => NativeWebEvent(
          e['viewId'] as int,
          e['type'] == 'webReady'
              ? NativeWebEventType.ready
              : NativeWebEventType.message,
          e['message'] as String?));
  Future<void> reply(int viewId, Map<String, Object?> message) => _client
      .invoke('webReply', {'viewId': viewId, 'json': jsonEncode(message)});
}
