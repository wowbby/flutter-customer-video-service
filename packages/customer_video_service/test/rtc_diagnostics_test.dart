import 'package:flutter_test/flutter_test.dart';
import 'package:customer_video_service/src/call/rtc_diagnostics.dart';

void main() {
  test('structured native errors retain only an allowlisted numeric SDK code',
      () {
    expect(
        rtcDiagnostic({
          'type': 'error',
          'code': 'sdkError',
          'details': {'sdkCode': 109, 'operation': 'private', 'token': 'secret'}
        }),
        'RTC error code=sdk_109');
    expect(
        rtcDiagnostic({
          'type': 'error',
          'code': 'sdkError',
          'details': {'sdkCode': 'private'}
        }),
        'RTC error');
  });
  test('only known event labels and numeric SDK diagnostics leave the boundary',
      () {
    expect(
        rtcDiagnostic({
          'type': 'error',
          'code': 'agora_110',
          'message': 'secret',
          'token': 'secret'
        }),
        'RTC error code=agora_110');
    expect(
        rtcDiagnostic({
          'type': 'connection',
          'state': 'failed',
          'reason': 8,
          'channel': 'secret'
        }),
        'RTC connection state=failed reason=8');
    expect(rtcDiagnostic({'type': 'error', 'code': 'secret'}), 'RTC error');
    expect(
        rtcDiagnostic(
            {'type': 'connection', 'state': 'secret', 'reason': 'secret'}),
        'RTC connection');
    expect(rtcDiagnostic({'type': 'secret'}), isNull);
    expect(
        rtcDiagnostic({'type': 'remoteVideo', 'uid': 123}), 'RTC remoteVideo');
  });
}
