import 'package:flutter/foundation.dart';

/// Host callbacks can synchronously close the call from a state notification.
/// Release ownership immediately, and clear ChangeNotifier's listener list only
/// after Flutter finishes iterating it.
class SessionNotifier extends ChangeNotifier {
  int _notificationDepth = 0;
  bool _disposePending = false;

  @override
  void notifyListeners() {
    if (_disposePending) return;
    _notificationDepth++;
    try {
      super.notifyListeners();
    } finally {
      _notificationDepth--;
      if (_disposePending && _notificationDepth == 0) super.dispose();
    }
  }

  @override
  void dispose() {
    if (_notificationDepth == 0) {
      super.dispose();
    } else {
      _disposePending = true;
    }
  }
}
