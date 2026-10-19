import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:haven_hub/api/location.dart';
import 'package:haven_hub/constant/index.dart';
import 'package:haven_hub/controller/build_controller.dart';
import 'package:haven_hub/pages/building/building_list.dart';
import 'package:haven_hub/pages/location/community_search.dart';
import 'package:haven_hub/pages/location/location_list.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:permission_handler/permission_handler.dart';

import 'helpers/widget_harness.dart';

const NearbyCommunity target = NearbyCommunity(
  id: 'liuyuan',
  name: '榴苑三街小区',
  address: '佛山市禅城区榴苑三街16号',
  latitude: 23.007933,
  longitude: 113.090276,
);
const LocationLookupResult rough = LocationLookupResult(
    address: '佛山市禅城区',
    city: '佛山市',
    isIpBased: true,
    communities: <NearbyCommunity>[]);

void main() {
  test('name search uses explicit city and query and retains usable identity',
      () async {
    final List<NearbyCommunity> found = await searchCommunitiesByName(
      ' 佛山市 ',
      ' 榴苑3街小区 ',
      apiKey: 'test',
      externalGet: (String url, {Map<String, dynamic>? params}) async {
        expect(url, HttpPath.tencentPlaceSearch);
        expect(params!['boundary'], 'region(佛山市,0)');
        expect(params['keyword'], '榴苑3街小区');
        expect(params['filter'], 'category=住宅小区,住宅区');
        return <String, dynamic>{
          'status': 0,
          'data': <dynamic>[
            <String, dynamic>{
              'id': 'liuyuan',
              'title': '榴苑三街小区',
              'address': target.address,
              'category': '房产小区:住宅小区',
              'location': <String, dynamic>{
                'lat': target.latitude,
                'lng': target.longitude
              }
            },
            <String, dynamic>{'title': '无坐标的结果', 'category': '住宅小区'},
          ]
        };
      },
    );
    expect(found.single.id, target.id);
    expect(found.single.latitude, target.latitude);
  });

  test('invalid city cannot alter the map boundary', () async {
    bool called = false;
    await expectLater(
        searchCommunitiesByName('佛山,1)', '小区', apiKey: 'test',
            externalGet: (String url, {Map<String, dynamic>? params}) async {
          called = true;
          return null;
        }),
        throwsFormatException);
    expect(called, isFalse);
  });

  testWidgets(
      'system switch failure is visible and settings return retries GPS',
      (tester) async {
    bool enabled = false;
    int systemOpens = 0;
    await pumpPage(
        tester,
        LocationList(
          permissionRequester: () async => PermissionStatus.granted,
          positionLoader: () async {
            if (!enabled) throw const LocationServiceDisabledException();
            return Position.fromMap(<String, Object>{
              'latitude': 23.01,
              'longitude': 113.08,
              'timestamp': DateTime.now().millisecondsSinceEpoch,
              'accuracy': 6.5,
              'altitude': 0.0,
              'speed': 0.0,
              'heading': 0.0,
              'is_mocked': true
            });
          },
          ipLocationLookup: () async => rough,
          locationLookup: (double lat, double lon,
                  {required bool isMocked}) async =>
              const LocationLookupResult(
                  address: '设备位置', communities: <NearbyCommunity>[target]),
          settingsOpener: () => throw StateError('must use system settings'),
          locationSettingsOpener: () async {
            systemOpens++;
            enabled = true;
            return true;
          },
        ));
    expect(find.text('系统定位服务未开启'), findsOneWidget);
    expect(find.text('大致位置（网络估算）'), findsOneWidget);
    await tester.tap(find.byKey(const Key('location-service-settings-button')));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(systemOpens, 1);
    expect(find.text('设备位置'), findsOneWidget);
    expect(find.byKey(const Key('location-approximate-notice')), findsNothing);
    expect(find.byKey(const Key('location-service-settings-button')),
        findsNothing);
    expect(find.byKey(const Key('location-retry-button')), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets(
      'search works after location failure and selects returned map identity',
      (tester) async {
    await pumpPage(
        tester,
        LocationList(
          permissionRequester: () async => PermissionStatus.denied,
          ipLocationLookup: () async => throw const NetworkException('网络不可用'),
          communitySearch: (String city, String keyword) async {
            expect(city, '佛山');
            expect(keyword, '榴苑三街');
            return <NearbyCommunity>[target];
          },
        ),
        routes: <String, WidgetBuilder>{
          BuildingList.routeName: (_) => const Scaffold(body: Text('楼栋选择页')),
        });
    await tester.pump(const Duration(seconds: 4));
    await tester.tap(find.byKey(const Key('community-search-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('community-search-city')), '佛山');
    await tester.enterText(
        find.byKey(const Key('community-search-keyword')), '榴苑三街');
    await tester.tap(find.byKey(const Key('community-search-submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(target.name));
    await tester.pumpAndSettle();
    expect(find.text('楼栋选择页'), findsOneWidget);
    expect(BuildController.instance().buildingInfo.communityId, target.id);
    expect(BuildController.instance().buildingInfo.latitude, target.latitude);
    BuildController.instance().clearBuildingInfo();
    await finishPage(tester);
  });

  testWidgets(
      'editing search discards old response and prevents duplicate submit',
      (tester) async {
    final Completer<List<NearbyCommunity>> old =
        Completer<List<NearbyCommunity>>();
    int calls = 0;
    await pumpPage(
        tester,
        CommunitySearchPage(
            initialCity: '佛山',
            search: (city, query) {
              calls++;
              return calls == 1
                  ? old.future
                  : Future.value(<NearbyCommunity>[target]);
            }));
    await tester.enterText(
        find.byKey(const Key('community-search-keyword')), '旧小区');
    await tester.tap(find.byKey(const Key('community-search-submit')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('community-search-submit')));
    expect(calls, 1);
    await tester.enterText(
        find.byKey(const Key('community-search-keyword')), '榴苑');
    await tester.pump();
    await tester.tap(find.byKey(const Key('community-search-submit')));
    await tester.pumpAndSettle();
    old.complete(const <NearbyCommunity>[]);
    await tester.pumpAndSettle();
    expect(find.text(target.name), findsOneWidget);
    expect(find.textContaining('没有找到匹配'), findsNothing);
    await finishPage(tester);
  });

  testWidgets('empty and timed out search can be retried; disposal is safe',
      (tester) async {
    int calls = 0;
    final Completer<List<NearbyCommunity>> pending =
        Completer<List<NearbyCommunity>>();
    await pumpPage(
        tester,
        CommunitySearchPage(
            initialCity: '佛山',
            search: (city, query) {
              return ++calls == 1
                  ? Future.value(<NearbyCommunity>[])
                  : pending.future;
            }));
    await tester.enterText(
        find.byKey(const Key('community-search-keyword')), '榴苑');
    await tester.tap(find.byKey(const Key('community-search-submit')));
    await tester.pumpAndSettle();
    expect(find.textContaining('没有找到匹配'), findsOneWidget);
    await tester.tap(find.byKey(const Key('community-search-submit')));
    await tester.pump(const Duration(seconds: 21));
    await tester.pumpAndSettle();
    expect(find.textContaining('搜索超时'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(<NearbyCommunity>[target]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await finishPage(tester);
  });
}
