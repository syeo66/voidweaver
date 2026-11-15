import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:material_ui/material_ui.dart';

import 'subsonic_api.dart';

final _log = Logger('image_cache');

/// Loads cover art with consistent caching: every image goes through here, so
/// the cache key ([SubsonicApi.coverArtCacheKey]) is the same everywhere.
class ImageCacheManager {
  /// Sizes cover art is requested at, in pixels. Each image is fetched at the
  /// smallest of these that covers its box in physical pixels, so the server
  /// and the cache keep a few sizes of a cover rather than one per box.
  static const coverArtSizes = [150, 300, 600, 1200];

  /// How many cover images the disk cache keeps, and for how long it keeps
  /// one that isn't used. The default manager holds 200 for 30 days, which
  /// scrolling through a library's album grid (each cover at one or two
  /// sizes) would push out, so covers wouldn't stay available offline. A
  /// cover is 5 to 300 KB depending on its size, so this stays well below a
  /// few hundred MB.
  @visibleForTesting
  static const maxCachedImages = 3000;
  @visibleForTesting
  static const cachedImageLifetime = Duration(days: 90);

  static CacheManager? _cacheManager;

  /// The login whose cover art is shown, set by `AppState` while logged in.
  /// While the server rejects its credentials, covers that aren't cached
  /// aren't fetched, see [CoverArtFileService].
  static SubsonicApi? currentApi;

  /// The disk cache of all cover art. Created on first use.
  static CacheManager get cacheManager => _cacheManager ??= CacheManager(
    Config(
      'voidweaverCoverArt',
      stalePeriod: cachedImageLifetime,
      maxNrOfCacheObjects: maxCachedImages,
      fileService: CoverArtFileService(() => currentApi),
    ),
  );

  /// Replaces the disk cache, which needs the platform's storage plugins; null
  /// goes back to the real one.
  @visibleForTesting
  static set cacheManager(CacheManager? manager) => _cacheManager = manager;

  // For a box that's unbounded in both directions
  static const _defaultCoverArtSize = 600;

  /// The size in [coverArtSizes] for a box whose longer side is [extent]
  /// logical pixels (null if unbounded).
  @visibleForTesting
  static int coverArtSizeFor(double? extent, double pixelRatio) {
    if (extent == null || !extent.isFinite) return _defaultCoverArtSize;
    final pixels = extent * pixelRatio;
    return coverArtSizes.firstWhere(
      (size) => size >= pixels,
      orElse: () => coverArtSizes.last,
    );
  }

  /// The longer finite side of a box [width] x [height] within
  /// [constraints], or null if both are unbounded
  static double? _extentOf(
    BoxConstraints constraints,
    double? width,
    double? height,
  ) {
    final sides = [
      width ?? constraints.maxWidth,
      height ?? constraints.maxHeight,
    ].where((side) => side.isFinite);
    return sides.isEmpty ? null : sides.reduce(math.max);
  }

  /// Cover art [coverArtId] of [api]'s server, fetched at a size that fits
  /// its box (see [coverArtSizes]) and decoded at the size in physical pixels
  /// when [width] and [height] are given
  static Widget buildCoverArt({
    required SubsonicApi api,
    required String coverArtId,
    Key? key,
    double? width,
    double? height,
    BoxFit? fit,
    Widget Function(BuildContext, String)? placeholder,
    Widget Function(BuildContext, String, dynamic)? errorWidget,
  }) {
    Widget image(BuildContext context, double? extent) {
      final pixelRatio = MediaQuery.devicePixelRatioOf(context);
      final size = coverArtSizeFor(extent, pixelRatio);
      return CachedNetworkImage(
        imageUrl: api.getCoverArtUrl(coverArtId, size: size),
        width: width,
        height: height,
        fit: fit ?? BoxFit.cover,
        cacheKey: api.coverArtCacheKey(coverArtId, size: size),
        cacheManager: cacheManager,
        placeholder:
            placeholder ?? (context, url) => _buildPlaceholder(context),
        errorWidget:
            errorWidget ??
            (context, url, error) => _buildErrorWidget(context, url, error),
        memCacheWidth: width == null ? null : (width * pixelRatio).round(),
        memCacheHeight: height == null ? null : (height * pixelRatio).round(),
        fadeInDuration: const Duration(milliseconds: 200),
        fadeOutDuration: const Duration(milliseconds: 100),
      );
    }

    if (width != null && height != null) {
      return Builder(
        key: key,
        builder: (context) => image(context, math.max(width, height)),
      );
    }
    // The box's size comes from the parent
    return LayoutBuilder(
      key: key,
      builder: (context, constraints) =>
          image(context, _extentOf(constraints, width, height)),
    );
  }

  /// Cover art as an [ImageProvider], e.g. for a [CircleAvatar], fetched at
  /// [size] pixels (one of [coverArtSizes])
  static ImageProvider coverArtProvider(
    SubsonicApi api,
    String coverArtId, {
    int size = 150,
  }) {
    return CachedNetworkImageProvider(
      api.getCoverArtUrl(coverArtId, size: size),
      cacheKey: api.coverArtCacheKey(coverArtId, size: size),
      cacheManager: cacheManager,
    );
  }

  /// Square album art with rounded corners
  static Widget buildAlbumArt({
    required SubsonicApi api,
    required String coverArtId,
    double size = 60,
  }) {
    return Builder(
      builder: (context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: buildCoverArt(
            api: api,
            coverArtId: coverArtId,
            width: size,
            height: size,
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }

  /// Default placeholder widget
  static Widget _buildPlaceholder(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(
            Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// Default error widget
  static Widget _buildErrorWidget(
    BuildContext context,
    String url,
    dynamic error,
  ) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.music_note,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        size: 24,
      ),
    );
  }

  /// Clear all cached images from disk and memory
  static Future<void> clearCache() async {
    await cacheManager.emptyCache();
    // Covers cached by versions that used the default manager
    await CachedNetworkImageProvider.defaultCacheManager.emptyCache();
    PaintingBinding.instance.imageCache.clear();
  }
}

/// Fetches cover art for [ImageCacheManager.cacheManager], which stores
/// every response with HTTP 200 as the image, for a week unless the server
/// says otherwise. A Subsonic server reports errors (also a rejected
/// password) with HTTP 200 and an XML document; stored, such a cover would
/// show as broken until then. So a document is an error here, as for the
/// player's audio (`ErrorDocumentGuard`).
///
/// For the login [api] returns (null: none), it also
/// - fetches nothing while the server rejects its credentials
///   ([SubsonicApi.hasRejectedCredentials]): every cover of a scrolled list
///   would be another failed login. Covers already cached still show.
/// - sets [SubsonicApi.credentialsRejected] when a cover is refused for the
///   credentials, see [SubsonicApi.checkRefusal]
/// - sends its `User-Agent` ([SubsonicApi.userAgent])
class CoverArtFileService extends FileService {
  CoverArtFileService(this._api, {http.Client? httpClient})
    : _client = httpClient ?? http.Client();

  final SubsonicApi? Function() _api;
  final http.Client _client;

  // A Subsonic error response is a few hundred bytes
  static const _maxDocumentBytes = 16 * 1024;

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final api = _api();
    if (api != null && api.hasRejectedCredentials) {
      throw const HttpException('Credentials rejected, cover art not fetched');
    }
    final request = http.Request('GET', Uri.parse(url));
    if (headers != null) request.headers.addAll(headers);
    if (api != null) request.headers['User-Agent'] = api.userAgent;
    final response = await _client.send(request);
    final type = response.headers['content-type'];
    if (response.statusCode == 200 && type != null && isDocument(type)) {
      final body = await _readStart(response.stream);
      final refused = api?.checkRefusal(body) ?? false;
      _log.fine(
        () =>
            'Got a document ($type) instead of cover art'
            '${refused ? ': credentials rejected' : ''}',
      );
      throw HttpException(
        refused
            ? 'Cover art refused: credentials rejected'
            : 'Got a document ($type) instead of cover art',
      );
    }
    return HttpGetResponse(response, request.url);
  }

  /// Whether [contentType] is a document rather than an image: XML or JSON
  /// (a Subsonic error) or any text (a reverse proxy's page), but no image
  /// type (`image/svg+xml`). Not a list of image types, which would fail art
  /// a server sends under a type nobody thought of
  /// (application/octet-stream, ...).
  @visibleForTesting
  static bool isDocument(String contentType) {
    final type = contentType.trim().toLowerCase();
    if (type.startsWith('image/')) return false;
    return type.startsWith('text/') ||
        type.contains('xml') ||
        type.contains('json');
  }

  /// The start of [stream], up to [_maxDocumentBytes]; the rest isn't read.
  static Future<String> _readStart(Stream<List<int>> stream) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      bytes.add(chunk);
      if (bytes.length >= _maxDocumentBytes) break;
    }
    final read = bytes.toBytes();
    return utf8.decode(
      read.length > _maxDocumentBytes
          ? read.sublist(0, _maxDocumentBytes)
          : read,
      allowMalformed: true,
    );
  }
}
