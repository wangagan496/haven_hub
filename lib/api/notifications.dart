import 'package:dio/dio.dart' show Options;

import '../constant/index.dart';
import '../utils/request_dio.dart';

Future<Map<String, dynamic>> notificationConfigApi() async =>
    Map<String, dynamic>.from(await requestDio.get(HttpPath.notificationConfig,
      options: Options(extra: <String, dynamic>{'privateResponse': true})) as Map);

Future<List<Map<String, dynamic>>> notificationsApi() async {
  final data = await requestDio.get(HttpPath.notifications);
  return (data as List).map((item) => Map<String, dynamic>.from(item as Map)).toList();
}

Future<void> registerNotificationsApi(Map<String, dynamic> registration) async {
  await requestDio.post(HttpPath.notificationDevices, data: registration,
      options: Options(extra: <String, dynamic>{'privateResponse': true}));
}

Future<void> unregisterNotificationsApi(String installationId) async {
  await requestDio.post(HttpPath.notificationUnregister,
      data: <String, dynamic>{'installationId': installationId},
      options: Options(extra: <String, dynamic>{'skipAuthorization': true, 'privateResponse': true}));
}

Future<Map<String, dynamic>> readNotificationApi(String id) async =>
    Map<String, dynamic>.from(await requestDio.post(HttpPath.notificationAction(id, 'read')) as Map);

Future<void> retryNotificationApi(String id) async {
  await requestDio.post(HttpPath.notificationAction(id, 'retry'));
}

Future<void> remindRepairApi(String id) async {
  await requestDio.post(HttpPath.repairRemind(id));
}
