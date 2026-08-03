import 'package:get/get.dart' show GetxController;

class BuildController extends GetxController {
  String build = '';
  String room = '';

  Map<String, dynamic> buildingInfo = <String, dynamic>{
    'name': '',
    'address': '',
    'build': '',
    'room': '',
  };

  void updateBuildingInfo(Map<String, dynamic> info) {
    build = '';
    room = '';
    buildingInfo = <String, dynamic>{
      ...info,
      'build': build,
      'room': room,
    };
    update();
  }

  void updateBuild(String value) {
    build = value.trim();
    room = '';
    buildingInfo = <String, dynamic>{
      ...buildingInfo,
      'build': build,
      'room': room,
    };
    update();
  }

  void updateRoom(String value) {
    room = value.trim();
    buildingInfo = <String, dynamic>{
      ...buildingInfo,
      'room': room,
    };
    update();
  }
}
