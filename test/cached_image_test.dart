import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/widgets/cached_image.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAASSURBVBhXY2Bg+P8fSMAAAwMAHPUB/xQxOT0AAAAASUVORK5CYII=',
);

class _ImageClient extends Fake implements HttpClient {
  final Completer<HttpClientResponse> response =
      Completer<HttpClientResponse>();
  int requests = 0;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests++;
    return _ImageRequest(response.future);
  }
}

class _ImageRequest extends Fake implements HttpClientRequest {
  _ImageRequest(this.response);
  final Future<HttpClientResponse> response;

  @override
  Future<HttpClientResponse> close() => response;
}

class _ImageResponse extends Stream<List<int>> implements HttpClientResponse {
  _ImageResponse({this.statusCode = HttpStatus.ok});

  @override
  final int statusCode;

  @override
  int get contentLength => _png.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.value(_png).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void imageTest(String description, WidgetTesterCallback body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
      debugNetworkImageHttpClientProvider = null;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _ImageClient client;
  int pathProviderCalls = 0;
  const MethodChannel pathProvider =
      MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.ohos;
    client = _ImageClient();
    debugNetworkImageHttpClientProvider = () => client;
    pathProviderCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async {
      pathProviderCalls++;
      throw MissingPluginException('No OHOS path_provider implementation');
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    debugNetworkImageHttpClientProvider = null;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
  });

  Future<void> finishImage(WidgetTester tester) async {
    for (int i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
      if (find.text('loading').evaluate().isEmpty) return;
    }
  }

  imageTest('OHOS loads and memory-caches avatars without path_provider',
      (tester) async {
    const Widget avatar = MaterialApp(
        home: CachedImage(
      imageUrl: 'https://example.invalid/avatar.png',
      width: 72,
      height: 72,
      placeholder: Text('loading'),
      errorWidget: Text('fallback'),
    ));
    await tester.pumpWidget(avatar);
    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.text('loading'), findsOneWidget);
    client.response.complete(_ImageResponse());
    await finishImage(tester);
    expect(find.text('loading'), findsNothing);
    expect(find.text('fallback'), findsNothing);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(pathProviderCalls, 0);
    expect(client.requests, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(avatar);
    await finishImage(tester);
    expect(client.requests, 1);
    expect(tester.takeException(), isNull);
  });

  imageTest('OHOS failed image shows supplied fallback rather than a spinner',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: CachedImage(
      imageUrl: 'https://example.invalid/missing.png',
      width: 72,
      height: 72,
      placeholder: Text('loading'),
      errorWidget: Text('fallback'),
    )));
    client.response.complete(_ImageResponse(statusCode: HttpStatus.notFound));
    await finishImage(tester);
    expect(find.text('fallback'), findsOneWidget);
    expect(find.text('loading'), findsNothing);
    expect(pathProviderCalls, 0);
    expect(tester.takeException(), isNull);
  });

  imageTest('OHOS preserves dimensions, fitting and rounded clipping',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: CachedImage(
      imageUrl: 'https://example.invalid/rounded.png',
      width: 72,
      height: 40,
      fit: BoxFit.contain,
      borderRadius: BorderRadius.circular(12),
      placeholder: const Text('loading'),
    ))));
    final Image image = tester.widget<Image>(find.byType(Image));
    expect(image.width, 72);
    expect(image.height, 40);
    expect(image.fit, BoxFit.contain);
    expect(tester.widget<ClipRRect>(find.byType(ClipRRect)).borderRadius,
        BorderRadius.circular(12));
    client.response.complete(_ImageResponse());
    await finishImage(tester);
    expect(tester.takeException(), isNull);
  });

  imageTest('other platforms retain the existing disk cache component',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    late Widget image;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      image = const CachedImage(
        imageUrl: 'https://example.invalid/android.png',
        width: 72,
        height: 72,
      ).build(context);
      // Inspect selection without starting a native disk cache in this test.
      return const SizedBox();
    })));
    expect(image, isA<CachedNetworkImage>());
    expect((image as CachedNetworkImage).maxWidthDiskCache, 1000);
    expect(pathProviderCalls, 0);
  });
}
