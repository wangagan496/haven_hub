/// 表单验证工具类。
///
/// 提供常用的表单字段验证方法，支持链式调用和自定义错误消息。
///
/// 使用示例：
/// ```dart
/// final error = Validators.required('姓名不能为空')
///     .chain(Validators.chineseName('姓名必须是2-15位中文'))
///     .validate(name);
/// ```
class Validators {
  const Validators._();

  // 常量正则表达式
  static final RegExp _ownerNamePattern = RegExp(r'^[一-龥]{2,15}$');
  static final RegExp _mobilePattern = RegExp(r'^1[3-9]\d{9}$');
  static final RegExp _emailPattern = RegExp(
    r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
  );
  static final RegExp _idCardPattern = RegExp(
    r'^\d{17}[\dXx]$',
  );

  /// 必填验证。
  ///
  /// [message] 验证失败时的错误提示。
  static Validator required([String message = '此字段不能为空']) {
    return Validator((String? value) {
      if (value == null || value.trim().isEmpty) {
        return message;
      }
      return null;
    });
  }

  /// 最小长度验证。
  ///
  /// [minLength] 最小字符数。
  /// [message] 自定义错误消息，为null时使用默认消息。
  static Validator minLength(int minLength, [String? message]) {
    return Validator((String? value) {
      if (value == null) return null;
      if (value.trim().length < minLength) {
        return message ?? '长度不能少于$minLength个字符';
      }
      return null;
    });
  }

  /// 最大长度验证。
  ///
  /// [maxLength] 最大字符数。
  /// [message] 自定义错误消息，为null时使用默认消息。
  static Validator maxLength(int maxLength, [String? message]) {
    return Validator((String? value) {
      if (value == null) return null;
      if (value.trim().length > maxLength) {
        return message ?? '长度不能超过$maxLength个字符';
      }
      return null;
    });
  }

  /// 中文姓名验证（2-15个汉字）。
  ///
  /// [message] 验证失败时的错误提示。
  static Validator chineseName([String message = '姓名必须是2-15位中文']) {
    return Validator((String? value) {
      if (value == null || value.isEmpty) return null;
      if (!_ownerNamePattern.hasMatch(value)) {
        return message;
      }
      return null;
    });
  }

  /// 手机号验证（中国大陆11位手机号）。
  ///
  /// [message] 验证失败时的错误提示。
  static Validator mobile([String message = '手机号格式不正确']) {
    return Validator((String? value) {
      if (value == null || value.isEmpty) return null;
      if (!_mobilePattern.hasMatch(value.trim())) {
        return message;
      }
      return null;
    });
  }

  /// 邮箱验证。
  ///
  /// [message] 验证失败时的错误提示。
  static Validator email([String message = '邮箱格式不正确']) {
    return Validator((String? value) {
      if (value == null || value.isEmpty) return null;
      if (!_emailPattern.hasMatch(value.trim())) {
        return message;
      }
      return null;
    });
  }

  /// 身份证号验证（18位）。
  ///
  /// [message] 验证失败时的错误提示。
  static Validator idCard([String message = '身份证号格式不正确']) {
    return Validator((String? value) {
      if (value == null || value.isEmpty) return null;
      if (!_idCardPattern.hasMatch(value.trim())) {
        return message;
      }
      return null;
    });
  }

  /// 自定义正则验证。
  ///
  /// [pattern] 正则表达式。
  /// [message] 验证失败时的错误提示。
  static Validator pattern(RegExp pattern, String message) {
    return Validator((String? value) {
      if (value == null || value.isEmpty) return null;
      if (!pattern.hasMatch(value)) {
        return message;
      }
      return null;
    });
  }

  /// 自定义验证函数。
  ///
  /// [validator] 验证函数，返回错误消息或null。
  static Validator custom(String? Function(String? value) validator) {
    return Validator(validator);
  }
}

/// 验证器类，支持链式调用。
class Validator {
  Validator(this._validate);

  final String? Function(String? value) _validate;
  final List<Validator> _chain = <Validator>[];

  /// 链接下一个验证器。
  ///
  /// 只有当前验证通过时，才会执行下一个验证器。
  Validator chain(Validator next) {
    _chain.add(next);
    return this;
  }

  /// 执行验证。
  ///
  /// 返回第一个验证失败的错误消息，全部通过返回 null。
  String? validate(String? value) {
    // 先执行当前验证器
    final String? error = _validate(value);
    if (error != null) {
      return error;
    }

    // 依次执行链上的验证器
    for (final Validator validator in _chain) {
      final String? chainError = validator._validate(value);
      if (chainError != null) {
        return chainError;
      }
    }

    return null;
  }

  /// 静态方法：组合多个验证器。
  ///
  /// 返回第一个验证失败的错误消息。
  static String? combine(String? value, List<Validator> validators) {
    for (final Validator validator in validators) {
      final String? error = validator.validate(value);
      if (error != null) {
        return error;
      }
    }
    return null;
  }
}
