import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/api/home.dart';
import 'package:haven_hub/pages/notifications/notification_page.dart';
import 'package:haven_hub/router/index.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.init();
  });
  Widget? resolve(String path) => getRouteWidget(path,
      announcementLoader: getAnnouncementListApi,
      announcementDetailLoader: getAnnouncementDetailApi);

  test('notification deep link requires login and retains the task id', () async {
    const id = '12345678-1234-1234-1234-123456789abc';
    await tokenManager.deleteToken();
    expect(resolve('/notifications/$id'), isA<FutureBuilder<void>>());
    await tokenManager.setToken('signed-in');
    final page = resolve('/notifications/$id')! as NotificationPage;
    expect(page.notificationId, id);
    expect((resolve('/notifications')! as NotificationPage).notificationId, isNull);
    expect(resolve('/notifications/invalid'), isNull);
  });

  test('cold-start notification link opens one notification page above home', () {
    const id = '12345678-1234-1234-1234-123456789abc';
    expect(initialRouteNames('/notifications/$id'), <String>['/', '/notifications/$id']);
    expect(initialRouteNames('/'), <String>['/']);
    expect(initialRouteNames(''), <String>['/']);
  });

  testWidgets('web cold start with a notification hash builds the page only once', (tester) async {
    const id = '12345678-1234-1234-1234-123456789abc';
    await tokenManager.setToken('signed-in');
    tester.binding.platformDispatcher.defaultRouteNameTestValue = '/notifications/$id';
    addTearDown(tester.binding.platformDispatcher.clearDefaultRouteNameTestValue);
    final routes = <String?>[];
    Route<void> route(RouteSettings settings) => MaterialPageRoute<void>(settings: settings,
        builder: (_) { routes.add(settings.name); return Text(settings.name ?? ''); });
    await tester.pumpWidget(MaterialApp(
      initialRoute: '/',
      onGenerateRoute: route,
      onGenerateInitialRoutes: (initial) =>
          initialRouteNames(initial).map((name) => route(RouteSettings(name: name))).toList(),
    ));
    await tester.pump();
    expect(routes.where((name) => name == '/notifications/$id'), hasLength(1));
    expect(routes.contains('/notifications'), isFalse);
  });
}
