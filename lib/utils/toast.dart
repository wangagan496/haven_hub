import 'dart:async';

import 'package:flutter/material.dart';

import '../constant/index.dart';

class PromptAction {
  const PromptAction._();

  static const Duration _displayDuration = Duration(seconds: 2);
  static OverlayEntry? _currentEntry;
  static Timer? _dismissTimer;

  // 正常消息
  static Future<bool?> showToast(String msg) {
    return _show(
      msg,
      textColor: Colors.white,
      backgroundColor: const Color(0xFF616161),
    );
  }

  // 成功消息
  static Future<bool?> showSuccess(String msg) {
    return _show(
      msg,
      textColor: Colors.white,
      backgroundColor: const Color(0xFF2E7D32),
    );
  }

  // 错误消息
  static Future<bool?> showError(String msg) {
    return _show(
      msg,
      textColor: Colors.white,
      backgroundColor: const Color(0xFFC62828),
    );
  }

  // 警告消息
  static Future<bool?> showWarning(String msg) {
    return _show(
      msg,
      textColor: Colors.black,
      backgroundColor: const Color(0xFFFFC107),
    );
  }

  static Future<bool?> _show(
    String msg, {
    required Color textColor,
    required Color backgroundColor,
  }) {
    final String message = msg.trim();
    final OverlayState? overlay =
        GlobalVariable.navigatorKey.currentState?.overlay;
    if (message.isEmpty || overlay == null) {
      return Future<bool?>.value(false);
    }

    _removeCurrent();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (BuildContext context) {
        return Positioned(
          left: 24,
          right: 24,
          bottom: 32 + MediaQuery.viewInsetsOf(context).bottom,
          child: SafeArea(
            top: false,
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Semantics(
                  container: true,
                  liveRegion: true,
                  label: message,
                  excludeSemantics: true,
                  child: Material(
                    color: backgroundColor,
                    elevation: 6,
                    borderRadius: BorderRadius.circular(8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Text(
                          message,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: textColor,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    _currentEntry = entry;
    overlay.insert(entry);
    _dismissTimer = Timer(_displayDuration, () {
      if (identical(_currentEntry, entry)) {
        _removeCurrent();
      }
    });
    return Future<bool?>.value(true);
  }

  static void _removeCurrent() {
    _dismissTimer?.cancel();
    _dismissTimer = null;

    final OverlayEntry? entry = _currentEntry;
    _currentEntry = null;
    if (entry == null) {
      return;
    }
    if (entry.mounted) {
      entry.remove();
    }
    entry.dispose();
  }
}
