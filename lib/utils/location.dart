import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

typedef PositionLoader = Future<Position> Function();
typedef PositionSampleObserver = void Function(double accuracy, bool isFresh);

// 选择社区允许用户核对结果；接受搜索范围内的估计误差，避免等待导航级精度。
const Duration _locationTimeout = Duration(seconds: 45);
const Duration _maximumPositionAge = Duration(minutes: 2);
const double _communityAccuracyInMeters = 1000;

/// 保留精度筛选失败的原因，与定位提供方直接报告的超时区分。
class PositionAcquisitionTimeout extends TimeoutException {
  PositionAcquisitionTimeout(String super.message, Duration super.duration);
}

Future<Position> getLocation({PositionSampleObserver? onSample}) async {
  final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) {
    throw const LocationServiceDisabledException();
  }

  return selectPrecisePosition(
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
      ),
    ),
    onSample: onSample,
  );
}

@visibleForTesting
Future<Position> selectPrecisePosition(
  Stream<Position> positions, {
  Duration timeout = _locationTimeout,
  DateTime Function() now = DateTime.now,
  PositionSampleObserver? onSample,
}) async {
  final Completer<Position> completer = Completer<Position>();
  Position? bestPosition;
  bool receivedSample = false;

  late final StreamSubscription<Position> subscription;
  late final Timer timer;

  void completeWithBestPosition() {
    if (completer.isCompleted) return;
    final Position? fallback = bestPosition;
    if (fallback != null && _isUsableCommunityPosition(fallback)) {
      completer.complete(fallback);
      return;
    }
    final String reason;
    if (!receivedSample) {
      reason = '设备定位等待结束，未收到任何位置';
    } else if (fallback == null) {
      reason = '设备已返回位置，但坐标无效或已过期';
    } else if (!fallback.accuracy.isFinite || fallback.accuracy <= 0) {
      reason = '设备已返回位置，但未提供有效的定位精度';
    } else {
      reason = '设备已返回位置，但最佳估计误差 '
          '${fallback.accuracy.toStringAsFixed(0)} 米，超过附近社区搜索允许的 '
          '${_communityAccuracyInMeters.toStringAsFixed(0)} 米';
    }
    completer.completeError(PositionAcquisitionTimeout(reason, timeout));
  }

  subscription = positions.listen(
    (Position position) {
      receivedSample = true;
      final bool fresh = _isFreshValidPosition(position, now());
      onSample?.call(position.accuracy, fresh);
      if (!fresh) return;

      final Position? currentBest = bestPosition;
      if (currentBest == null ||
          _accuracyScore(position) < _accuracyScore(currentBest)) {
        bestPosition = position;
      }

      if (_isUsableCommunityPosition(position) && !completer.isCompleted) {
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

bool _isUsableCommunityPosition(Position position) {
  final double accuracy = position.accuracy;
  return accuracy.isFinite &&
      accuracy > 0 &&
      accuracy <= _communityAccuracyInMeters;
}

double _accuracyScore(Position position) {
  final double accuracy = position.accuracy;
  return accuracy.isFinite && accuracy > 0 ? accuracy : double.infinity;
}
