// ignore_for_file: file_names

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../controller/build_controller.dart';

class HouseForm extends StatefulWidget {
  const HouseForm({super.key});

  static const String routeName = '/houseform';

  @override
  State<HouseForm> createState() => _HouseFormState();
}

class _HouseFormState extends State<HouseForm> {
  late final BuildController _controller;
  final Map<String, dynamic> _formData = <String, dynamic>{
    'name': '',
    'gender': 1,
    'mobile': '',
    'idcardFrontUrl': '',
    'idcardBackUrl': '',
  };

  @override
  void initState() {
    super.initState();
    _controller = Get.isRegistered<BuildController>()
        ? Get.find<BuildController>()
        : Get.put(BuildController());
  }

  Widget _buildAddIdcardPhoto(String info) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        const Icon(
          Icons.add,
          size: 30,
          color: Color(0xFF5591AF),
        ),
        Text(
          info,
          style: const TextStyle(color: Color(0xFF5591AF)),
        ),
      ],
    );
  }

  Widget _buildIdcardPhoto(String tag, String photoUrl) {
    return Stack(
      children: <Widget>[
        SizedBox(
          width: double.infinity,
          height: 300,
          child: Image.asset(photoUrl, fit: BoxFit.contain),
        ),
        Positioned(
          right: 0,
          top: 0,
          child: IconButton(
            icon: const Icon(Icons.delete, color: Colors.red),
            tooltip: '删除照片',
            onPressed: () {
              setState(() => _formData[tag] = '');
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F3F8),
      appBar: AppBar(
        title: const Text('添加房屋信息'),
        centerTitle: true,
        backgroundColor: const Color(0xFFF8F3F8),
        surfaceTintColor: Colors.transparent,
      ),
      body: GetBuilder<BuildController>(
        init: _controller,
        builder: (BuildController controller) {
          final String houseLabel = <String>[
            controller.build,
            controller.room,
          ].where((String value) => value.isNotEmpty).join(' ');

          return ListView(
            padding: const EdgeInsets.only(top: 10, bottom: 10),
            children: <Widget>[
              const _FormSectionTitle('房屋信息'),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 15,
                ),
                child: Text(
                  houseLabel.isEmpty ? '尚未选择房屋' : houseLabel,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
              const _FormSectionTitle('业主信息'),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: TextField(
                  maxLength: 15,
                  onChanged: (String value) => _formData['name'] = value,
                  decoration: const InputDecoration(
                    labelText: '姓名',
                    hintText: '请输入业主姓名',
                    hintStyle: TextStyle(color: Colors.grey),
                    border: InputBorder.none,
                  ),
                  inputFormatters: <TextInputFormatter>[
                    LengthLimitingTextInputFormatter(15),
                  ],
                ),
              ),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: RadioGroup<int>(
                  groupValue: _formData['gender'] as int,
                  onChanged: (int? value) {
                    if (value == null) return;
                    setState(() => _formData['gender'] = value);
                  },
                  child: const Row(
                    children: <Widget>[
                      Text('性别', style: TextStyle(fontSize: 16)),
                      SizedBox(width: 20),
                      Radio<int>(value: 1),
                      Text('男'),
                      SizedBox(width: 10),
                      Radio<int>(value: 0),
                      Text('女'),
                    ],
                  ),
                ),
              ),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: TextField(
                  keyboardType: TextInputType.phone,
                  maxLength: 11,
                  onChanged: (String value) => _formData['mobile'] = value,
                  decoration: const InputDecoration(
                    labelText: '手机号',
                    hintText: '请输入您的手机号',
                    hintStyle: TextStyle(color: Colors.grey),
                    border: InputBorder.none,
                  ),
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(11),
                  ],
                ),
              ),
              const _FormSectionTitle('本人身份证照片'),
              const Padding(
                padding: EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: Text(
                  '请拍摄证件原件，并使照片中证件边缘完整，文字清晰，光线均匀。',
                  style: TextStyle(color: Color(0xFF615E5E), fontSize: 12),
                ),
              ),
              Container(
                color: Colors.white,
                height: 320,
                padding: const EdgeInsets.all(10),
                child: _formData['idcardFrontUrl'] == ''
                    ? _buildAddIdcardPhoto('上传人像面照片')
                    : _buildIdcardPhoto(
                        'idcardFrontUrl',
                        _formData['idcardFrontUrl'] as String,
                      ),
              ),
              const SizedBox(height: 20),
              Container(
                color: Colors.white,
                height: 320,
                padding: const EdgeInsets.all(10),
                child: _formData['idcardBackUrl'] == ''
                    ? _buildAddIdcardPhoto('上传国徽面照片')
                    : _buildIdcardPhoto(
                        'idcardBackUrl',
                        _formData['idcardBackUrl'] as String,
                      ),
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.all(10),
                child: SizedBox(
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.exit_to_app),
                    label: const Text('提交审核'),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _FormSectionTitle extends StatelessWidget {
  const _FormSectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Text(
        title,
        style: const TextStyle(color: Color(0xFF615E5E), fontSize: 16),
      ),
    );
  }
}
