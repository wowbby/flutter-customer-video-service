import 'dart:async';
import 'package:flutter/services.dart';
import '../models.dart';

/// Only structured numeric SDK information crosses the native error boundary.
CallException callFailure(Object error, {required CallOperation operation}) {
  if (error is CallException) return error;
  final code = CallErrorCode.values.firstWhere(
    (value) => value.name == safeErrorCode(error),
    orElse: () => CallErrorCode.operationFailed,
  );
  int? vendorCode;
  var recovery =
      operation == CallOperation.join || operation == CallOperation.event
          ? CallRecovery.retryCall
          : CallRecovery.retryOperation;
  if (error is PlatformException) {
    final numeric =
        RegExp(r'^(?:sdk|agora)_(-?\d{1,6})$').firstMatch(error.code);
    vendorCode = numeric == null ? null : int.tryParse(numeric.group(1)!);
    final details = error.details;
    if (details is Map) {
      final sdkCode = details['sdkCode'];
      if (sdkCode is int && sdkCode.abs() <= 999999) vendorCode = sdkCode;
      // Only a native cleanup failure can require restarting the engine/app.
      if (code == CallErrorCode.cleanupFailed &&
          details['recovery'] == 'restartRequired') {
        recovery = CallRecovery.restartRequired;
      }
    }
  }
  return CallException(code,
      operation: operation, vendorCode: vendorCode, recovery: recovery);
}

String safeErrorCode(Object error) {
  if (error is CallException) return error.code.name;
  if (error is TimeoutException) return 'timeout';
  if (error is MissingPluginException) return 'bridgeUnavailable';
  if (error is PlatformException) {
    if (RegExp(r'^(?:sdk|agora)_-?\d{1,6}$').hasMatch(error.code)) {
      return 'sdkError';
    }
    const aliases = {
      'system_call_busy': 'systemCallBusy',
      'permission_denied': 'permissionDenied',
      'permission_failed': 'permissionDenied',
      'no_activity': 'missingActivity',
      'missing_activity': 'missingActivity',
      'invalid_arguments': 'invalidArgument',
      'no_session': 'notInitialized',
      'no_active_session': 'notInitialized',
      'rtc_error': 'sdkError',
      'rtc_join_failed': 'sdkError',
      'join_failed': 'sdkError',
      'rtc_operation_failed': 'sdkError',
      'cleanup_failed': 'cleanupFailed',
    };
    const known = {
      'permissionDenied',
      'busy',
      'invalidArgument',
      'notInitialized',
      'cancelled',
      'sdkError',
      'missingActivity',
      'unsupported',
      'cleanupFailed'
    };
    return aliases[error.code] ??
        (known.contains(error.code) ? error.code : 'nativeError');
  }
  if (error is ArgumentError) return 'invalidConfiguration';
  return 'operationFailed';
}
