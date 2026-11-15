import 'package:flutter/material.dart';
import 'package:get/get.dart' show GetBuilder;
import '../controller/build_controller.dart';
import '../router/app_routes.dart';
import '../utils/token_manager.dart';

/// 切换时退出本次页面栈，已输入内容由对应草稿保留。
class HouseDraftActions extends StatelessWidget {
  const HouseDraftActions({super.key, this.enabled = true});
  final bool enabled;
  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: '切换选房草稿',
        icon: const Icon(Icons.drafts_outlined),
        onPressed: !enabled
            ? null
            : () => Navigator.pushNamedAndRemoveUntil<void>(
                context,
                houseDrafts,
                (route) => route.settings.name == houseList || route.isFirst),
      );
}

/// 换号或草稿被清理后，旧页面不再显示原账号的房屋与证件资料。
class HouseDraftGuard extends StatelessWidget {
  const HouseDraftGuard(
      {required this.draftId, required this.child, super.key, this.sessionId});
  final String? draftId;
  final int? sessionId;
  final Widget child;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: tokenManager.sessionChanges,
        builder: (context, session, _) => GetBuilder<BuildController>(
          init: BuildController.instance(),
          autoRemove: false,
          builder: (controller) {
            final active = (sessionId == null || sessionId == session) &&
                (draftId == null || controller.draftFor(draftId!) != null);
            if (active) return child;
            return Scaffold(
                appBar: AppBar(title: const Text('选房流程已结束')),
                body: Center(
                    child: TextButton(
                        onPressed: () =>
                            Navigator.pushReplacementNamed<void, void>(
                                context, houseDrafts),
                        child: const Text('返回选房草稿'))));
          },
        ),
      );
}
