import 'package:flutter/material.dart';

import 'repair_detail_page.dart';
import 'repair_form_page.dart';

/// 打开新增报修页，返回页面报告的新增结果；没有返回结果时为 null。
Future<bool?> openNewRepairPage(BuildContext context) {
  return Navigator.pushNamed<bool>(context, RepairFormPage.routeName);
}

/// 打开指定工单的详情页，返回页面报告的工单变化结果。
Future<bool?> openRepairDetailPage(BuildContext context, String repairId) {
  return Navigator.pushNamed<bool>(
    context,
    RepairDetailPage.routeName,
    arguments: repairId,
  );
}
