import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/request_dio.dart';
import 'package:haven_hub/utils/toast.dart';

import '../helpers/widget_harness.dart';

const receipt = 'd63b531e-fbb5-44b5-893e-46c5203a3b2e';

class ReceiptAdapter implements HttpClientAdapter {
  ReceiptAdapter({this.status = 500, this.id = receipt, this.offline = false});
  final int status;
  final String id;
  final bool offline;
  int calls = 0;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancel) async {
    calls++;
    if (offline) {
      throw DioException(requestOptions: options,
          type: DioExceptionType.connectionTimeout);
    }
    return ResponseBody.fromString(jsonEncode(<String, dynamic>{
      'code': 50000, 'message': '服务暂时不可用', 'data': null,
    }), status, headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      'x-request-id': <String>[id],
    });
  }
  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('HTTP and business failures carry only the response receipt', () async {
    for (final status in <int>[200, 500]) {
      final dio = Dio()..httpClientAdapter = ReceiptAdapter(status: status);
      addTearDown(dio.close);
      final client = RequestDio(client: dio);
      try {
        await client.post('repair');
        fail('request should fail');
      } on Object catch (error) {
        expect(errorRequestId(error), receipt);
        expect(error, status == 200 ? isA<BusinessException>() : isA<NetworkException>());
      }
    }
  });

  test('exhausted safe-read retry preserves the last receipt', () async {
    final adapter = ReceiptAdapter(status: 503);
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    await expectLater(RequestDio(client: dio).get('userInfo'),
        throwsA(isA<NetworkException>()
            .having((error) => error.requestId, 'receipt', receipt)
            .having((error) => error.retryHandled, 'budget spent', true)));
    expect(adapter.calls, 3);
  });

  test('offline, invalid headers and external errors have no server receipt', () async {
    for (final adapter in <ReceiptAdapter>[
      ReceiptAdapter(offline: true), ReceiptAdapter(id: 'phone=13800138000'),
    ]) {
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      await expectLater(RequestDio(client: dio).post('repair'),
          throwsA(isA<NetworkException>().having((error) => error.requestId, 'receipt', isNull)));
    }
    final dio = Dio()..httpClientAdapter = ReceiptAdapter();
    addTearDown(dio.close);
    await expectLater(RequestDio(client: dio).getExternal('https://example.test/map'),
        throwsA(isA<NetworkException>().having((error) => error.requestId, 'receipt', isNull)));
  });

  testWidgets('error prompt copies only the request id', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await pumpPage(tester, const Scaffold());
    await AppPrompt.showException(const NetworkException('请求失败', requestId: receipt), fallback: '失败');
    await tester.pump();
    expect(find.text('排查编号：$receipt'), findsOneWidget);
    await tester.tap(find.text('复制排查编号'));
    await tester.pump();
    expect(copied, receipt);
    expect(find.text('排查编号已复制'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('offline prompt never offers a fabricated server id', (tester) async {
    await pumpPage(tester, const Scaffold());
    await AppPrompt.showException(const NetworkException('网络不可用'), fallback: '失败');
    await tester.pump();
    expect(find.text('复制排查编号'), findsNothing);
    expect(find.text('网络不可用'), findsOneWidget);
    await finishPage(tester);
  });
}
