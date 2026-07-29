import 'package:flutter/material.dart';

import '../../utils/toast.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  static const String routeName = '/profile';

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final TextEditingController _nicknameController = TextEditingController();
  bool _isSaving = false;

  Future<void> _saveProfile() async {
    if (_isSaving) {
      return;
    }

    final String nickname = _nicknameController.text.trim();
    if (nickname.isEmpty) {
      await PromptAction.showWarning('请输入昵称');
      return;
    }

    setState(() {
      _isSaving = true;
    });
    try {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted) {
        return;
      }

      await PromptAction.showSuccess('保存成功');
      if (!mounted) {
        return;
      }

      Navigator.maybePop(context);
    } on Object {
      await PromptAction.showError('保存失败，请重试');
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('个人信息'),
        backgroundColor: Colors.transparent,
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(10),
        children: <Widget>[
          SizedBox(
            height: 40,
            child: Row(
              children: <Widget>[
                const Text(
                  '头像',
                  style: TextStyle(fontSize: 16),
                ),
                const Spacer(),
                Row(
                  children: <Widget>[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(50),
                      child: Image.asset(
                        'assets/images/avatar_1.jpg',
                        width: 30,
                        height: 30,
                      ),
                    ),
                    const Icon(Icons.arrow_forward_ios, size: 12),
                  ],
                ),
              ],
            ),
          ),
          Row(
            children: <Widget>[
              const Text('昵称'),
              const Spacer(),
              Expanded(
                child: TextField(
                  controller: _nicknameController,
                  decoration: const InputDecoration(
                    hintText: '请输入昵称',
                    border: InputBorder.none,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
              const Icon(Icons.arrow_forward_ios, size: 12),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: <Widget>[
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color.fromARGB(255, 85, 145, 175),
                    minimumSize: const Size(100, 50),
                  ),
                  onPressed: _isSaving ? null : _saveProfile,
                  child: _isSaving
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          '保存',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
