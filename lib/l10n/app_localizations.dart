import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh')
  ];

  /// 应用标题
  ///
  /// In zh, this message translates to:
  /// **'享家社区'**
  String get appTitle;

  /// No description provided for @home.
  ///
  /// In zh, this message translates to:
  /// **'首页'**
  String get home;

  /// No description provided for @mine.
  ///
  /// In zh, this message translates to:
  /// **'我的'**
  String get mine;

  /// No description provided for @login.
  ///
  /// In zh, this message translates to:
  /// **'登录'**
  String get login;

  /// No description provided for @logout.
  ///
  /// In zh, this message translates to:
  /// **'退出登录'**
  String get logout;

  /// No description provided for @profile.
  ///
  /// In zh, this message translates to:
  /// **'个人资料'**
  String get profile;

  /// No description provided for @settings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get settings;

  /// No description provided for @houseManagement.
  ///
  /// In zh, this message translates to:
  /// **'房屋管理'**
  String get houseManagement;

  /// No description provided for @myHouses.
  ///
  /// In zh, this message translates to:
  /// **'我的房屋'**
  String get myHouses;

  /// No description provided for @addHouse.
  ///
  /// In zh, this message translates to:
  /// **'添加房屋'**
  String get addHouse;

  /// No description provided for @editHouse.
  ///
  /// In zh, this message translates to:
  /// **'修改房屋信息'**
  String get editHouse;

  /// No description provided for @houseDetail.
  ///
  /// In zh, this message translates to:
  /// **'房屋详情'**
  String get houseDetail;

  /// No description provided for @deleteHouse.
  ///
  /// In zh, this message translates to:
  /// **'删除房屋'**
  String get deleteHouse;

  /// No description provided for @community.
  ///
  /// In zh, this message translates to:
  /// **'小区'**
  String get community;

  /// No description provided for @building.
  ///
  /// In zh, this message translates to:
  /// **'楼栋'**
  String get building;

  /// No description provided for @room.
  ///
  /// In zh, this message translates to:
  /// **'房间'**
  String get room;

  /// No description provided for @ownerName.
  ///
  /// In zh, this message translates to:
  /// **'业主姓名'**
  String get ownerName;

  /// No description provided for @gender.
  ///
  /// In zh, this message translates to:
  /// **'性别'**
  String get gender;

  /// No description provided for @male.
  ///
  /// In zh, this message translates to:
  /// **'男'**
  String get male;

  /// No description provided for @female.
  ///
  /// In zh, this message translates to:
  /// **'女'**
  String get female;

  /// No description provided for @mobile.
  ///
  /// In zh, this message translates to:
  /// **'手机号'**
  String get mobile;

  /// No description provided for @idCard.
  ///
  /// In zh, this message translates to:
  /// **'身份证'**
  String get idCard;

  /// No description provided for @selectCommunity.
  ///
  /// In zh, this message translates to:
  /// **'选择小区'**
  String get selectCommunity;

  /// No description provided for @selectBuilding.
  ///
  /// In zh, this message translates to:
  /// **'选择楼栋'**
  String get selectBuilding;

  /// No description provided for @selectRoom.
  ///
  /// In zh, this message translates to:
  /// **'选择房间'**
  String get selectRoom;

  /// No description provided for @submit.
  ///
  /// In zh, this message translates to:
  /// **'提交'**
  String get submit;

  /// No description provided for @submitForReview.
  ///
  /// In zh, this message translates to:
  /// **'提交审核'**
  String get submitForReview;

  /// No description provided for @cancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get cancel;

  /// No description provided for @confirm.
  ///
  /// In zh, this message translates to:
  /// **'确定'**
  String get confirm;

  /// No description provided for @save.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get save;

  /// No description provided for @delete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get delete;

  /// No description provided for @edit.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get edit;

  /// No description provided for @refresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get refresh;

  /// No description provided for @retry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get retry;

  /// No description provided for @back.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get back;

  /// No description provided for @loading.
  ///
  /// In zh, this message translates to:
  /// **'加载中...'**
  String get loading;

  /// No description provided for @loadingFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败'**
  String get loadingFailed;

  /// No description provided for @noData.
  ///
  /// In zh, this message translates to:
  /// **'暂无数据'**
  String get noData;

  /// No description provided for @networkError.
  ///
  /// In zh, this message translates to:
  /// **'网络错误'**
  String get networkError;

  /// No description provided for @serverError.
  ///
  /// In zh, this message translates to:
  /// **'服务器错误'**
  String get serverError;

  /// No description provided for @success.
  ///
  /// In zh, this message translates to:
  /// **'成功'**
  String get success;

  /// No description provided for @failed.
  ///
  /// In zh, this message translates to:
  /// **'失败'**
  String get failed;

  /// No description provided for @addSuccess.
  ///
  /// In zh, this message translates to:
  /// **'添加成功'**
  String get addSuccess;

  /// No description provided for @updateSuccess.
  ///
  /// In zh, this message translates to:
  /// **'修改成功'**
  String get updateSuccess;

  /// No description provided for @deleteSuccess.
  ///
  /// In zh, this message translates to:
  /// **'删除成功'**
  String get deleteSuccess;

  /// No description provided for @pleaseEnter.
  ///
  /// In zh, this message translates to:
  /// **'请输入'**
  String get pleaseEnter;

  /// No description provided for @pleaseSelect.
  ///
  /// In zh, this message translates to:
  /// **'请选择'**
  String get pleaseSelect;

  /// No description provided for @required.
  ///
  /// In zh, this message translates to:
  /// **'不能为空'**
  String get required;

  /// No description provided for @errorRequired.
  ///
  /// In zh, this message translates to:
  /// **'{field}不能为空'**
  String errorRequired(String field);

  /// No description provided for @errorInvalidFormat.
  ///
  /// In zh, this message translates to:
  /// **'{field}格式不正确'**
  String errorInvalidFormat(String field);

  /// No description provided for @errorMinLength.
  ///
  /// In zh, this message translates to:
  /// **'{field}长度不能少于{min}个字符'**
  String errorMinLength(String field, int min);

  /// No description provided for @errorMaxLength.
  ///
  /// In zh, this message translates to:
  /// **'{field}长度不能超过{max}个字符'**
  String errorMaxLength(String field, int max);

  /// No description provided for @uploadPhoto.
  ///
  /// In zh, this message translates to:
  /// **'上传照片'**
  String get uploadPhoto;

  /// No description provided for @takePhoto.
  ///
  /// In zh, this message translates to:
  /// **'拍照'**
  String get takePhoto;

  /// No description provided for @chooseFromGallery.
  ///
  /// In zh, this message translates to:
  /// **'从相册选择'**
  String get chooseFromGallery;

  /// No description provided for @uploadIdCardFront.
  ///
  /// In zh, this message translates to:
  /// **'上传人像面照片'**
  String get uploadIdCardFront;

  /// No description provided for @uploadIdCardBack.
  ///
  /// In zh, this message translates to:
  /// **'上传国徽面照片'**
  String get uploadIdCardBack;

  /// No description provided for @houseStatus.
  ///
  /// In zh, this message translates to:
  /// **'房屋状态'**
  String get houseStatus;

  /// No description provided for @statusPending.
  ///
  /// In zh, this message translates to:
  /// **'待审核'**
  String get statusPending;

  /// No description provided for @statusApproved.
  ///
  /// In zh, this message translates to:
  /// **'审核通过'**
  String get statusApproved;

  /// No description provided for @statusRejected.
  ///
  /// In zh, this message translates to:
  /// **'审核未通过'**
  String get statusRejected;

  /// No description provided for @confirmDelete.
  ///
  /// In zh, this message translates to:
  /// **'确认删除？'**
  String get confirmDelete;

  /// No description provided for @confirmDeleteMessage.
  ///
  /// In zh, this message translates to:
  /// **'删除后将无法恢复'**
  String get confirmDeleteMessage;

  /// No description provided for @announcement.
  ///
  /// In zh, this message translates to:
  /// **'公告'**
  String get announcement;

  /// No description provided for @announcementDetail.
  ///
  /// In zh, this message translates to:
  /// **'公告详情'**
  String get announcementDetail;

  /// No description provided for @noAnnouncement.
  ///
  /// In zh, this message translates to:
  /// **'暂无公告'**
  String get noAnnouncement;

  /// No description provided for @location.
  ///
  /// In zh, this message translates to:
  /// **'位置'**
  String get location;

  /// No description provided for @currentLocation.
  ///
  /// In zh, this message translates to:
  /// **'当前位置'**
  String get currentLocation;

  /// No description provided for @relocate.
  ///
  /// In zh, this message translates to:
  /// **'重新定位'**
  String get relocate;

  /// No description provided for @nearbyCommunities.
  ///
  /// In zh, this message translates to:
  /// **'附近小区'**
  String get nearbyCommunities;

  /// No description provided for @pageLoadError.
  ///
  /// In zh, this message translates to:
  /// **'页面加载失败'**
  String get pageLoadError;

  /// No description provided for @pageLoadErrorMessage.
  ///
  /// In zh, this message translates to:
  /// **'抱歉，页面遇到了一些问题'**
  String get pageLoadErrorMessage;

  /// No description provided for @reload.
  ///
  /// In zh, this message translates to:
  /// **'重新加载'**
  String get reload;

  /// No description provided for @viewDetails.
  ///
  /// In zh, this message translates to:
  /// **'查看详情'**
  String get viewDetails;

  /// No description provided for @errorDetails.
  ///
  /// In zh, this message translates to:
  /// **'错误详情'**
  String get errorDetails;

  /// No description provided for @errorMessage.
  ///
  /// In zh, this message translates to:
  /// **'错误信息'**
  String get errorMessage;

  /// No description provided for @stackTrace.
  ///
  /// In zh, this message translates to:
  /// **'堆栈跟踪'**
  String get stackTrace;

  /// No description provided for @close.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get close;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
