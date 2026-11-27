/// Allowlist diagnostics: never serialize a native event or free-form message.
String? rtcDiagnostic(Map<String, dynamic> event) {
  const types = {
    'joined',
    'remoteJoined',
    'remoteVideo',
    'remoteLeft',
    'connection',
    'tokenRequired',
    'error'
  };
  final type = event['type'];
  if (!types.contains(type)) return null;
  var result = 'RTC $type';
  if (type == 'error') {
    final code = event['code'];
    if (code is String && RegExp(r'^(agora|sdk)_-?\d{1,6}$').hasMatch(code)) {
      result += ' code=$code';
    } else if (code == 'sdkError') {
      final details = event['details'];
      final sdkCode = details is Map ? details['sdkCode'] : null;
      if (sdkCode is int && sdkCode.abs() <= 999999) {
        result += ' code=sdk_$sdkCode';
      }
    }
  }
  if (type == 'connection') {
    const states = {
      'disconnected',
      'connecting',
      'connected',
      'reconnecting',
      'failed'
    };
    final state = event['state'];
    if (states.contains(state)) result += ' state=$state';
    final reason = event['reason'];
    if (reason is int) result += ' reason=$reason';
  }
  return result;
}
