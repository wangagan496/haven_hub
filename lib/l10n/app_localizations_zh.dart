// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => '享家社区';

  @override
  String get home => '首页';

  @override
  String get mine => '我的';

  @override
  String get login => '登录';

  @override
  String get logout => '退出登录';

  @override
  String get profile => '个人资料';

  @override
  String get settings => '设置';

  @override
  String get houseManagement => '房屋管理';

  @override
  String get myHouses => '我的房屋';

  @override
  String get addHouse => '添加房屋';

  @override
  String get editHouse => '修改房屋信息';

  @override
  String get houseDetail => '房屋详情';

  @override
  String get deleteHouse => '删除房屋';

  @override
  String get community => '小区';

  @override
  String get building => '楼栋';

  @override
  String get room => '房间';

  @override
  String get ownerName => '业主姓名';

  @override
  String get gender => '性别';

  @override
  String get male => '男';

  @override
  String get female => '女';

  @override
  String get mobile => '手机号';

  @override
  String get idCard => '身份证';

  @override
  String get selectCommunity => '选择小区';

  @override
  String get selectBuilding => '选择楼栋';

  @override
  String get selectRoom => '选择房间';

  @override
  String get submit => '提交';

  @override
  String get submitForReview => '提交审核';

  @override
  String get cancel => '取消';

  @override
  String get confirm => '确定';

  @override
  String get save => '保存';

  @override
  String get delete => '删除';

  @override
  String get edit => '编辑';

  @override
  String get refresh => '刷新';

  @override
  String get retry => '重试';

  @override
  String get back => '返回';

  @override
  String get loading => '加载中...';

  @override
  String get loadingFailed => '加载失败';

  @override
  String get noData => '暂无数据';

  @override
  String get networkError => '网络错误';

  @override
  String get serverError => '服务器错误';

  @override
  String get success => '成功';

  @override
  String get failed => '失败';

  @override
  String get addSuccess => '添加成功';

  @override
  String get updateSuccess => '修改成功';

  @override
  String get deleteSuccess => '删除成功';

  @override
  String get pleaseEnter => '请输入';

  @override
  String get pleaseSelect => '请选择';

  @override
  String get required => '不能为空';

  @override
  String errorRequired(String field) {
    return '$field不能为空';
  }

  @override
  String errorInvalidFormat(String field) {
    return '$field格式不正确';
  }

  @override
  String errorMinLength(String field, int min) {
    return '$field长度不能少于$min个字符';
  }

  @override
  String errorMaxLength(String field, int max) {
    return '$field长度不能超过$max个字符';
  }

  @override
  String get uploadPhoto => '上传照片';

  @override
  String get takePhoto => '拍照';

  @override
  String get chooseFromGallery => '从相册选择';

  @override
  String get uploadIdCardFront => '上传人像面照片';

  @override
  String get uploadIdCardBack => '上传国徽面照片';

  @override
  String get houseStatus => '房屋状态';

  @override
  String get statusPending => '待审核';

  @override
  String get statusApproved => '审核通过';

  @override
  String get statusRejected => '审核未通过';

  @override
  String get confirmDelete => '确认删除？';

  @override
  String get confirmDeleteMessage => '删除后将无法恢复';

  @override
  String get announcement => '公告';

  @override
  String get announcementDetail => '公告详情';

  @override
  String get noAnnouncement => '暂无公告';

  @override
  String get location => '位置';

  @override
  String get currentLocation => '当前位置';

  @override
  String get relocate => '重新定位';

  @override
  String get nearbyCommunities => '附近小区';

  @override
  String get pageLoadError => '页面加载失败';

  @override
  String get pageLoadErrorMessage => '抱歉，页面遇到了一些问题';

  @override
  String get reload => '重新加载';

  @override
  String get viewDetails => '查看详情';

  @override
  String get errorDetails => '错误详情';

  @override
  String get errorMessage => '错误信息';

  @override
  String get stackTrace => '堆栈跟踪';

  @override
  String get close => '关闭';
}
