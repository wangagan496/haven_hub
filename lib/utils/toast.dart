import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';

class PromptAction {
  const PromptAction._();

  // 正常消息
  static Future<bool?> showToast(String msg) {
    return Fluttertoast.showToast(
      msg: msg,
      textColor: Colors.black,
      backgroundColor: const Color.fromARGB(255, 210, 207, 207),
    );
  }

  // 成功消息
  static Future<bool?> showSuccess(String msg) {
    return Fluttertoast.showToast(
      msg: msg,
      textColor: Colors.white,
      backgroundColor: const Color.fromARGB(255, 85, 238, 164),
    );
  }

  // 错误消息
  static Future<bool?> showError(String msg) {
    return Fluttertoast.showToast(
      msg: msg,
      textColor: Colors.white,
      backgroundColor: Colors.red,
    );
  }

  // 警告消息
  static Future<bool?> showWarning(String msg) {
    return Fluttertoast.showToast(
      msg: msg,
      textColor: Colors.black12,
      backgroundColor: Colors.yellowAccent,
    );
  }
}
