import 'dart:io';

bool isTemporarySocketFailure(Object? error) => error is SocketException &&
    const <int>{54, 104, 10054, 53, 103, 10053, 60, 110, 10060}
        .contains(error.osError?.errorCode);
