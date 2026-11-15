import 'package:flutter/foundation.dart';

/// The repository wrapper supplies pubspec/build-name, never the server's minimum.
/// Unwrapped builds without a define report no version and fail a configured gate.
class ClientIdentity {
  const ClientIdentity({required this.version, required this.platform});

  final String version;
  final String platform;

  static ClientIdentity get current => ClientIdentity(
        version: const String.fromEnvironment('HAVEN_CLIENT_VERSION'),
        platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
      );

  Map<String, String> get headers => <String, String>{
        'X-Client-Version': version,
        'X-Client-Platform': platform,
      };
}
