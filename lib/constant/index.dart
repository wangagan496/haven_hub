class GlobalVariable {
  const GlobalVariable._();

  static const String baseUrl = 'https://live-api.itheima.net/';
  static const Duration networkTimeout = Duration(seconds: 10);
  static const int successCode = 10000;
}

class HttpPath {
  const HttpPath._();

  static const String announcement = 'announcement';
}
