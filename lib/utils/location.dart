import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

typedef PositionLoader = Future<Position> Function();

// 给 GPS 足够时间完成冷启动和卫星收敛，避免过早接受网络/基站粗略位置。
const Duration _locationTimeout = Duration(seconds: 45);
const Duration _maximumPositionAge = Duration(minutes: 2);
const double _targetAccuracyInMeters = 10;
const double _fallbackAccuracyInMeters = 50;

Future<Position> getLocation() async {
  final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) {
    throw const LocationServiceDisabledException();
  }

  return selectPrecisePosition(
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
      ),
    ),
  );
}

@visibleForTesting
Future<Position> selectPrecisePosition(
  Stream<Position> positions, {
  Duration timeout = _locationTimeout,
  DateTime Function() now = DateTime.now,
}) async {
  final Completer<Position> completer = Completer<Position>();
  Position? bestPosition;

  late final StreamSubscription<Position> subscription;
  late final Timer timer;

  void completeWithBestPosition() {
    if (completer.isCompleted) return;
    final Position? fallback = bestPosition;
    if (fallback != null && _isUsableFallback(fallback)) {
      completer.complete(fallback);
      return;
    }
    completer.completeError(
      TimeoutException('未能在限定时间内获取精确定位', timeout),
    );
  }

  subscription = positions.listen(
    (Position position) {
      if (!_isFreshValidPosition(position, now())) return;

      final Position? currentBest = bestPosition;
      if (currentBest == null ||
          _accuracyScore(position) < _accuracyScore(currentBest)) {
        bestPosition = position;
      }

      if (_accuracyScore(position) <= _targetAccuracyInMeters &&
          !completer.isCompleted) {
        completer.complete(position);
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    },
    onDone: completeWithBestPosition,
    cancelOnError: false,
  );
  timer = Timer(timeout, completeWithBestPosition);

  try {
    return await completer.future;
  } finally {
    timer.cancel();
    await subscription.cancel();
  }
}

bool _isFreshValidPosition(Position position, DateTime now) {
  if (!position.latitude.isFinite ||
      position.latitude < -90 ||
      position.latitude > 90 ||
      !position.longitude.isFinite ||
      position.longitude < -180 ||
      position.longitude > 180) {
    return false;
  }

  final DateTime? timestamp = position.timestamp;
  return timestamp == null ||
      now.difference(timestamp.toLocal()).abs() <= _maximumPositionAge;
}

bool _isUsableFallback(Position position) {
  final double accuracy = _accuracyScore(position);
  return accuracy <= _fallbackAccuracyInMeters || !accuracy.isFinite;
}

double _accuracyScore(Position position) {
  final double accuracy = position.accuracy;
  return accuracy.isFinite && accuracy > 0 ? accuracy : double.infinity;
}
