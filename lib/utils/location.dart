import 'package:geolocator/geolocator.dart';

typedef PositionLoader = Future<Position> Function();

Future<Position> getLocation() async {
  final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) {
    throw const LocationServiceDisabledException();
  }

  return Geolocator.getCurrentPosition(
    desiredAccuracy: LocationAccuracy.high,
  ).timeout(const Duration(seconds: 15));
}
