import 'dart:async';
import 'package:flutter/widgets.dart';
import 'toast.dart';

/// Lives only until this attempt's reminder is delivered, even if its page left.
class VisitorShareReminder with WidgetsBindingObserver {
  bool _queued = false;
  bool _delivered = false;
  void interrupt() {
    if (_queued || _delivered) return;
    _queued = true;
    WidgetsBinding.instance.addObserver(this);
    _deliverWhenVisible();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _deliverWhenVisible();
  }

  void _deliverWhenVisible() {
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final current = WidgetsBinding.instance.lifecycleState;
      if (_delivered || (current != null && current != AppLifecycleState.resumed)) return;
      _delivered = true;
      WidgetsBinding.instance.removeObserver(this);
      unawaited(PromptAction.showWarning('刚才的分享未完成，请返回通行码页面重新分享'));
    });
    WidgetsBinding.instance.scheduleFrame();
  }
}
