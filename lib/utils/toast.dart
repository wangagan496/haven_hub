import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constant/index.dart';
import 'app_exception.dart';

class AppPrompt {
  const AppPrompt._();

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
  static Future<bool?> showError(String msg, {String? requestId}) {
    return _show(
      msg,
      textColor: Colors.white,
      backgroundColor: const Color(0xFFC62828),
      requestId: validRequestId(requestId),
    );
  }

  static Future<bool?> showException(Object error, {required String fallback}) {
    return showError(describeError(error, fallback: fallback),
        requestId: errorRequestId(error));
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
    String? requestId,
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
              ignoring: requestId == null,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Semantics(
                  container: true,
                  liveRegion: true,
                  label: message,
                  excludeSemantics: requestId == null,
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
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(message, textAlign: TextAlign.center,
                                style: TextStyle(color: textColor, fontSize: 14)),
                            if (requestId != null) ...<Widget>[
                              const SizedBox(height: 8),
                              Text('排查编号：$requestId', textAlign: TextAlign.center,
                                  style: TextStyle(color: textColor, fontSize: 12)),
                              TextButton.icon(
                                style: TextButton.styleFrom(foregroundColor: textColor),
                                onPressed: () async {
                                  try {
                                    await Clipboard.setData(ClipboardData(text: requestId));
                                    if (identical(_currentEntry, entry)) await showSuccess('排查编号已复制');
                                  } on Object {
                                    if (identical(_currentEntry, entry)) await showWarning('复制失败，请记录排查编号');
                                  }
                                },
                                icon: const Icon(Icons.copy, size: 18),
                                label: const Text('复制排查编号'),
                              ),
                            ],
                          ],
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
    _dismissTimer = Timer(requestId == null ? _displayDuration : const Duration(seconds: 10), () {
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
    // insert() attaches the entry before its first frame sets mounted=true.
    // Every stored entry was inserted and must be removed before disposal.
    entry
      ..remove()
      ..dispose();
  }
}
