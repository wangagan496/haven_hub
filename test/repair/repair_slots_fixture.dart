import 'package:haven_hub/models/repair.dart';

RepairSlots slotsFixture({String date = '2030-10-20', Set<int> unavailable = const <int>{}}) => RepairSlots(
  today: '2030-10-20', dates: const ['2030-10-20', '2030-10-21'],
  slots: [for (final hour in [8, 9, 10, 11, 14, 15, 16, 17, 19, 20, 21])
    RepairSlot(slot: '$date#${hour.toString().padLeft(2, '0')}',
      start: '${date}T${hour.toString().padLeft(2, '0')}:00:00+08:00',
      end: '${date}T${(hour + 1).toString().padLeft(2, '0')}:00:00+08:00',
      period: hour < 12 ? 'morning' : hour < 18 ? 'afternoon' : 'evening',
      selectable: !unavailable.contains(hour))]);

Future<RepairSlots> loadSlotsFixture({String? date, String? excludeId, String? repairItemId}) async => slotsFixture(date: date ?? '2030-10-20');
