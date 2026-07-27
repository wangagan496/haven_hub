import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/constant/index.dart';
import 'package:haven_hub/main.dart';
import 'package:haven_hub/pages/login/index.dart';
import 'package:haven_hub/pages/profile/index.dart';
import 'package:haven_hub/router/index.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<List<Map<String, dynamic>>> _announcementLoader() async {
  return <Map<String, dynamic>>[];
}

Future<Map<String, dynamic>> _announcementDetailLoader(String id) async {
  return <String, dynamic>{'id': id};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('init 初始化 token，后续 getToken 同步读取', () async {
    SharedPreferences.setMockInitialValues(
      <String, Object>{
        GlobalVariable.tokenKey: 'saved-token',
        GlobalVariable.refreshTokenKey: 'saved-refresh-token',
      },
    );

    await tokenManager.init();

    expect(tokenManager.getToken(), 'saved-token');
    expect(tokenManager.getRefreshToken(), 'saved-refresh-token');

    await tokenManager.deleteToken();
    expect(tokenManager.getToken(), isEmpty);
    expect(tokenManager.getRefreshToken(), isEmpty);
  });

  testWidgets('访问 profile 时没有 token 显示登录页', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.init();

    await tester.pumpWidget(
      MaterialApp(
        home: getRouteWidget(
          ProfilePage.routeName,
          announcementLoader: _announcementLoader,
          announcementDetailLoader: _announcementDetailLoader,
        ),
      ),
    );

    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byType(ProfilePage), findsNothing);
  });

  testWidgets('访问 profile 时有 token 显示个人信息页', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(
      <String, Object>{GlobalVariable.tokenKey: 'saved-token'},
    );
    await tokenManager.init();

    await tester.pumpWidget(
      MaterialApp(
        home: getRouteWidget(
          ProfilePage.routeName,
          announcementLoader: _announcementLoader,
          announcementDetailLoader: _announcementDetailLoader,
        ),
      ),
    );

    expect(find.byType(ProfilePage), findsOneWidget);
    expect(find.byType(LoginPage), findsNothing);
  });

  testWidgets('无 token 时点击去完善信息被拦截到登录页', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.init();

    await tester.pumpWidget(
      const HavenHubApp(announcementLoader: _announcementLoader),
    );
    await tester.tap(find.text('我的'));
    await tester.pump();
    await tester.tap(find.text('去完善信息'));
    await tester.pumpAndSettle();

    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byType(ProfilePage), findsNothing);
  });

  testWidgets('有 token 时点击去完善信息进入个人信息页', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(
      <String, Object>{GlobalVariable.tokenKey: 'saved-token'},
    );
    await tokenManager.init();

    await tester.pumpWidget(
      const HavenHubApp(announcementLoader: _announcementLoader),
    );
    await tester.tap(find.text('我的'));
    await tester.pump();
    await tester.tap(find.text('去完善信息'));
    await tester.pumpAndSettle();

    expect(find.byType(ProfilePage), findsOneWidget);
    expect(find.byType(LoginPage), findsNothing);
  });
}
