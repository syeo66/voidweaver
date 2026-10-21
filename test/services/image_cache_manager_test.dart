import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/services/image_cache_manager.dart';
import 'package:voidweaver/services/subsonic_api.dart';

void main() {
  group('ImageCacheManager.coverArtSizeFor', () {
    test('picks the smallest size covering the box in physical pixels', () {
      expect(ImageCacheManager.coverArtSizeFor(50, 2.625), 150);
      expect(ImageCacheManager.coverArtSizeFor(56, 3), 300);
      // The now-playing art on a Pixel 8
      expect(ImageCacheManager.coverArtSizeFor(200, 2.625), 600);
      expect(ImageCacheManager.coverArtSizeFor(200, 1), 300);
    });

    test('takes the largest size for a box bigger than all sizes', () {
      expect(ImageCacheManager.coverArtSizeFor(800, 3), 1200);
    });

    test('takes a medium size for an unbounded box', () {
      expect(ImageCacheManager.coverArtSizeFor(null, 3), 600);
      expect(ImageCacheManager.coverArtSizeFor(double.infinity, 3), 600);
    });
  });

  group('ImageCacheManager.buildCoverArt', () {
    late SubsonicApi api;

    setUp(() {
      api = SubsonicApi(
        serverUrl: 'https://music.example.com',
        username: 'testuser',
        password: 'testpass',
      );
    });

    tearDown(() => api.dispose());

    Future<CachedNetworkImage> pumpCover(WidgetTester tester, Widget cover,
        {double pixelRatio = 3}) async {
      await tester.pumpWidget(MediaQuery(
        data: MediaQueryData(devicePixelRatio: pixelRatio),
        child: Center(child: cover),
      ));
      return tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
    }

    testWidgets('fetches the size of the given width and height',
        (tester) async {
      final image = await pumpCover(
          tester,
          ImageCacheManager.buildCoverArt(
              api: api, coverArtId: 'al-1', width: 50, height: 50));

      expect(Uri.parse(image.imageUrl).queryParameters['size'], '150');
      expect(image.cacheKey, api.coverArtCacheKey('al-1', size: 150));
    });

    testWidgets('fetches the size of the box it is laid out in',
        (tester) async {
      final image = await pumpCover(
          tester,
          SizedBox(
              width: 200,
              height: 200,
              child: ImageCacheManager.buildCoverArt(
                  api: api, coverArtId: 'al-1')));

      expect(Uri.parse(image.imageUrl).queryParameters['size'], '600');
      expect(image.cacheKey, api.coverArtCacheKey('al-1', size: 600));
    });
  });
}
