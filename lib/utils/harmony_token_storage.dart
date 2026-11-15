import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constant/index.dart';
import 'token_storage.dart';

/// Credentials only cross the native channel into Asset Store's SECRET field.
/// Old preferences are deleted, never imported: upgrading requires one login.
class HarmonyTokenStorage implements TokenStorage {
  HarmonyTokenStorage({
    MethodChannel channel = const MethodChannel('haven_hub/secure_tokens'),
    SharedPreferencesLoader? preferencesLoader,
  })  : _channel = channel,
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  final MethodChannel _channel;
  final SharedPreferencesLoader _preferencesLoader;
  String _token = '';
  String _refreshToken = '';
  int _generation = 0;
  int _pending = 0;
  Future<void> _tail = Future<void>.value();

  @override
  String get token => _token;
  @override
  String get refreshToken => _refreshToken;

  Future<T> _serialize<T>(Future<T> Function() action) {
    final previous = _pending == 0 ? Future<void>.value() : _tail;
    _pending++;
    final operation = previous.then((_) => action());
    _tail = operation
        .then<void>((_) {}, onError: (Object _, StackTrace __) {})
        .whenComplete(() => _pending--);
    return operation;
  }

  Future<bool> _removeLegacyCredentials() async {
    try {
      final preferences = await _preferencesLoader();
      // Always attempt both removals, including when the first one fails.
      final tokenRemoved =
          await _removePreference(preferences, GlobalVariable.tokenKey);
      final refreshRemoved =
          await _removePreference(preferences, GlobalVariable.refreshTokenKey);
      return tokenRemoved && refreshRemoved;
    } on Object {
      return false;
    }
  }

  Future<bool> _removePreference(
      SharedPreferences preferences, String key) async {
    try {
      return await preferences.remove(key);
    } on Object {
      return false;
    }
  }

  static String _encode(String token, String refreshToken) => jsonEncode(
        <String, Object>{
          'version': 1,
          'token': token,
          'refreshToken': refreshToken,
        },
      );

  @override
  Future<void> load() {
    final generation = _generation;
    return _serialize(() async {
      // A queued load must not resurrect an invalidated session.
      if (_generation != generation) return;
      _token = '';
      _refreshToken = '';
      if (!await _removeLegacyCredentials()) {
        throw PlatformException(
          code: 'legacy_cleanup_failed',
          message: '旧登录凭证清理失败，请重试',
        );
      }
      final payload = await _channel.invokeMethod<String>('read');
      Object? decoded;
      try {
        if (payload == null || utf8.encode(payload).length > 1024) {
          throw const FormatException();
        }
        decoded = jsonDecode(payload);
        if (decoded is! Map<String, dynamic> ||
            decoded['version'] != 1 ||
            decoded['token'] is! String ||
            decoded['refreshToken'] is! String) {
          throw const FormatException();
        }
      } on Object {
        // Do not attach corrupt payloads or system messages to diagnostics.
        throw const FormatException('安全登录凭证格式无效，请清除登录状态后重试');
      }
      if (_generation != generation) return;
      _token = decoded['token'] as String;
      _refreshToken = decoded['refreshToken'] as String;
    });
  }

  @override
  Future<bool> write(String token, String refreshToken) {
    final generation = _generation;
    return _serialize(() async {
      final payload = _encode(token, refreshToken);
      if (utf8.encode(payload).length > 1024) return false;
      try {
        if (!await _removeLegacyCredentials()) return false;
        await _channel.invokeMethod<void>('write', <String, String>{
          'payload': payload,
        });
        if (_generation != generation) return false;
        _token = token;
        _refreshToken = refreshToken;
        return true;
      } on Object {
        return false;
      }
    });
  }

  @override
  Future<bool> clear() {
    invalidate();
    return _serialize(() async {
      final legacyCleared = await _removeLegacyCredentials();
      try {
        // Keep an empty authoritative record; never fall back to old tokens.
        await _channel.invokeMethod<void>('clear');
        return legacyCleared;
      } on Object {
        return false;
      }
    });
  }

  @override
  void invalidate() {
    _generation++;
    _token = '';
    _refreshToken = '';
  }
}
