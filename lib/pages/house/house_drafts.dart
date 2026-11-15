import 'package:flutter/material.dart';
import 'package:get/get.dart' show GetBuilder;
import '../../controller/build_controller.dart';
import '../../router/app_routes.dart';

class HouseDraftsPage extends StatelessWidget {
  const HouseDraftsPage({super.key});

  Future<void> _open(BuildContext context, HouseSelectionDraft draft,
      {bool changeSelection = false}) async {
    final controller = BuildController.instance();
    if (!controller.activateDraft(draft.id)) return;
    final route = changeSelection ? locationList : switch (draft.step) {
      HouseSelectionStep.community => locationList,
      HouseSelectionStep.building => buildingList,
      HouseSelectionStep.room => roomList,
      HouseSelectionStep.owner => houseForm,
    };
    await Navigator.pushNamed<void>(context, route,
        arguments: route == houseForm
            ? HouseFormArguments(mode: HouseFormMode.create, draftId: draft.id)
            : HouseSelectionArguments(draft.id));
    if (context.mounted) controller.update();
  }

  Future<void> _discard(BuildContext context, String id) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('放弃这份草稿？'),
              content: const Text('只清理这份选房草稿，其他草稿和已发送的待确认提交回执不受影响。'),
              actions: <Widget>[
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('保留')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('放弃')),
              ],
            ));
    if (!context.mounted || confirmed != true) return;
    BuildController.instance().discardDraft(id);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('选房草稿')),
        body: GetBuilder<BuildController>(
          init: BuildController.instance(),
          autoRemove: false,
          builder: (controller) =>
              ListView(padding: const EdgeInsets.all(16), children: <Widget>[
            const Text('选房草稿仅在本次登录期间保留，退出账号或关闭应用后清空；已发送的待确认提交会单独保存，再次进入添加房屋可查询结果。'),
            const SizedBox(height: 12),
            FilledButton.icon(
                onPressed: () {
                  final id = controller.startDraft();
                  _open(context, controller.draftFor(id)!);
                },
                icon: const Icon(Icons.add),
                label: const Text('新建选房草稿')),
            if (controller.drafts.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Text('暂无选房草稿')),
            for (final draft in controller.drafts)
              Card(
                  key: ValueKey(draft.id),
                  child: ListTile(
                    title: Text(draft.selection.name.isEmpty
                        ? '尚未选择小区'
                        : draft.selection.name),
                    subtitle: Text(<String>[
                      draft.selection.building,
                      draft.selection.room,
                      draft.form.name
                    ].where((value) => value.isNotEmpty).join(' · ')),
                    onTap: () => _open(context, draft),
                    trailing: PopupMenuButton<String>(
                        tooltip: '草稿操作',
                        onSelected: (action) {
                          if (action == 'discard') {
                            _discard(context, draft.id);
                          } else {
                            _open(context, draft, changeSelection: true);
                          }
                        },
                        itemBuilder: (_) => const <PopupMenuEntry<String>>[
                              PopupMenuItem(
                                  value: 'selection', child: Text('修改选房')),
                              PopupMenuItem(
                                  value: 'discard', child: Text('放弃草稿')),
                            ]),
                  )),
          ]),
        ),
      );
}
