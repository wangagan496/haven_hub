import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../api/user.dart';
import '../../utils/app_exception.dart';
import '../../utils/emitter.dart';
import '../../utils/toast.dart';
import '../../utils/token_manager.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({
    this.toName,
    this.toArguments,
    this.sendCodeLoader = sendCodeApi,
    this.loginLoader = loginApi,
    this.enableDevelopmentCodeAutofill = kDebugMode,
    super.key,
  });

  static const String routeName = '/login';

  final String? toName;

  /// 登录成功回跳到 [toName] 时透传的 route arguments。
  final Object? toArguments;
  final SendCodeLoader sendCodeLoader;
  final LoginLoader loginLoader;
  final bool enableDevelopmentCodeAutofill;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  // 匹配中国大陆手机号，支持“13800138000”和“+8613800138000”。
  static final RegExp _mobilePattern = RegExp(r'^(?:\+86)?1[3-9]\d{9}$');
  static final RegExp _codePattern = RegExp(r'^\d{6}$');

  // 分别控制手机号和验证码输入框。
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();

  int _remainingSeconds = 60;
  Timer? _timer;
  bool isSend = false;
  bool _isLoggingIn = false;

  Future<void> _sendCode() async {
    if (isSend) {
      return;
    }

    final String mobileInput = _phoneController.text.trim();
    if (mobileInput.isEmpty) {
      await PromptAction.showWarning('请输入手机号');
      return;
    }
    if (!_mobilePattern.hasMatch(mobileInput)) {
      await PromptAction.showWarning('请输入正确的手机号（支持 +86）');
      return;
    }
    final String mobile = _normalizeMobile(mobileInput);

    setState(() {
      isSend = true;
    });
    try {
      final Map<String, dynamic> result = await widget.sendCodeLoader(mobile);
      if (!mounted) {
        return;
      }

      final String? developmentCode =
          kDebugMode && widget.enableDevelopmentCodeAutofill
              ? _extractVerificationCode(result)
              : null;
      if (developmentCode != null) {
        _codeController.text = developmentCode;
        await PromptAction.showSuccess('验证码已获取并自动填入');
      } else {
        await PromptAction.showSuccess('验证码已发送，请查收短信');
      }
      if (!mounted) {
        return;
      }

      _startCountdown();
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          isSend = false;
        });
      }
      await PromptAction.showError(describeError(error, fallback: '操作失败，请重试'));
    }
  }

  void _startCountdown() {
    _timer?.cancel();
    setState(() {
      _remainingSeconds = 60;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (_remainingSeconds <= 1) {
        timer.cancel();
        _timer = null;
        setState(() {
          _remainingSeconds = 60;
          isSend = false;
        });
        return;
      }

      setState(() {
        _remainingSeconds--;
      });
    });
  }

  Future<void> _login() async {
    if (_isLoggingIn) {
      return;
    }

    final String mobileInput = _phoneController.text.trim();
    final String code = _codeController.text.trim();
    if (mobileInput.isEmpty || code.isEmpty) {
      await PromptAction.showWarning('手机号和验证码不能为空');
      return;
    }
    if (!_mobilePattern.hasMatch(mobileInput) || !_codePattern.hasMatch(code)) {
      await PromptAction.showWarning('手机号或验证码格式不正确');
      return;
    }
    final String mobile = _normalizeMobile(mobileInput);

    setState(() {
      _isLoggingIn = true;
    });
    try {
      final Map<String, dynamic> result =
          await widget.loginLoader(mobile, code);
      final String token = result['token']?.toString() ?? '';
      final String refreshToken = result['refreshToken']?.toString() ?? '';
      if (token.isEmpty) {
        throw const FormatException('登录接口未返回 token');
      }

      final bool saved = await tokenManager.setToken(
        token,
        refreshToken: refreshToken,
      );
      if (!saved) {
        throw const FormatException('登录状态保存失败');
      }
      if (!mounted) {
        return;
      }

      eventBus.fire(const LoginSuccessEvent());
      await PromptAction.showSuccess('登录成功');
      if (!mounted) {
        return;
      }

      final String? toName = widget.toName;
      if (toName != null && toName.isNotEmpty) {
        Navigator.pushReplacementNamed(
          context,
          toName,
          arguments: widget.toArguments,
        );
        return;
      }
      Navigator.maybePop(context);
    } on Object catch (error) {
      await PromptAction.showError(describeError(error, fallback: '操作失败，请重试'));
    } finally {
      if (mounted) {
        setState(() {
          _isLoggingIn = false;
        });
      }
    }
  }

  String _normalizeMobile(String mobile) {
    return mobile.replaceFirst(RegExp(r'^\+86'), '');
  }

  String? _extractVerificationCode(Map<String, dynamic> result) {
    for (final String key in const <String>[
      'code',
      'smsCode',
      'verificationCode',
    ]) {
      final String value = result[key]?.toString().trim() ?? '';
      if (_codePattern.hasMatch(value)) {
        return value;
      }
    }
    return null;
  }

  Widget _getCodeButtonText() {
    if (isSend && _timer == null) {
      return const Text('发送中...');
    }
    if (_timer != null) {
      return Text(
        '重新获取(${_remainingSeconds}s)',
        style: const TextStyle(color: Colors.grey),
      );
    }
    return const Text('获取验证码');
  }

  @override
  void dispose() {
    _timer?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('登录'),
        backgroundColor: Colors.transparent,
        centerTitle: true,
      ),
      body: Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: <Widget>[
            const Row(
              children: <Widget>[
                Text(
                  '登录',
                  style: TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Row(
              children: <Widget>[
                Text(
                  '加入享+, 让生活更轻松',
                  style: TextStyle(fontSize: 15),
                ),
              ],
            ),
            const SizedBox(height: 30),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: '手机号',
                      hintText: '请输入手机号（可带 +86）',
                    ),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    shadowColor: Colors.transparent,
                    foregroundColor: const Color.fromARGB(255, 85, 145, 175),
                    minimumSize: const Size(100, 50),
                  ),
                  onPressed: isSend ? null : _sendCode,
                  child: _getCodeButtonText(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _codeController,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              maxLength: 6,
              onSubmitted: (_) => _login(),
              decoration: InputDecoration(
                labelText: '验证码',
                hintText: '请输入6位验证码',
                counterText: '',
              ),
            ),
            const SizedBox(height: 8),
            const Row(
              children: <Widget>[
                Text(
                  '未注册手机号经验证后将自动登录',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 50),
            Row(
              children: <Widget>[
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color.fromARGB(255, 85, 145, 175),
                      minimumSize: const Size(100, 50),
                    ),
                    onPressed: _isLoggingIn ? null : _login,
                    child: _isLoggingIn
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            '登录',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
