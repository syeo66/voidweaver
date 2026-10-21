import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'subsonic_api.dart';

/// Loads cover art with consistent caching: every image goes through here, so
/// the cache key ([SubsonicApi.coverArtCacheKey]) is the same everywhere.
class ImageCacheManager {
  /// Sizes cover art is requested at, in pixels. Each image is fetched at the
  /// smallest of these that covers its box in physical pixels, so the server
  /// and the cache keep a few sizes of a cover rather than one per box.
  static const coverArtSizes = [150, 300, 600, 1200];

  // For a box that's unbounded in both directions
  static const _defaultCoverArtSize = 600;

  /// The size in [coverArtSizes] for a box whose longer side is [extent]
  /// logical pixels (null if unbounded).
  @visibleForTesting
  static int coverArtSizeFor(double? extent, double pixelRatio) {
    if (extent == null || !extent.isFinite) return _defaultCoverArtSize;
    final pixels = extent * pixelRatio;
    return coverArtSizes.firstWhere((size) => size >= pixels,
        orElse: () => coverArtSizes.last);
  }

  /// The longer finite side of a box [width] x [height] within
  /// [constraints], or null if both are unbounded
  static double? _extentOf(
      BoxConstraints constraints, double? width, double? height) {
    final sides = [
      width ?? constraints.maxWidth,
      height ?? constraints.maxHeight
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
        placeholder: placeholder ?? (context, url) => _buildPlaceholder(),
        errorWidget: errorWidget ??
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
          builder: (context) => image(context, math.max(width, height)));
    }
    // The box's size comes from the parent
    return LayoutBuilder(
        key: key,
        builder: (context, constraints) =>
            image(context, _extentOf(constraints, width, height)));
  }

  /// Cover art as an [ImageProvider], e.g. for a [CircleAvatar], fetched at
  /// [size] pixels (one of [coverArtSizes])
  static ImageProvider coverArtProvider(SubsonicApi api, String coverArtId,
      {int size = 150}) {
    return CachedNetworkImageProvider(
      api.getCoverArtUrl(coverArtId, size: size),
      cacheKey: api.coverArtCacheKey(coverArtId, size: size),
    );
  }

  /// Square album art with rounded corners
  static Widget buildAlbumArt({
    required SubsonicApi api,
    required String coverArtId,
    double size = 60,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Colors.grey[300],
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
    );
  }

  /// Default placeholder widget
  static Widget _buildPlaceholder() {
    return Container(
      color: Colors.grey[200],
      child: const Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(Colors.grey),
        ),
      ),
    );
  }

  /// Default error widget
  static Widget _buildErrorWidget(
      BuildContext context, String url, dynamic error) {
    return Container(
      color: Colors.grey[300],
      child: const Icon(
        Icons.music_note,
        color: Colors.grey,
        size: 24,
      ),
    );
  }

  /// Clear all cached images from disk and memory
  static Future<void> clearCache() async {
    await CachedNetworkImageProvider.defaultCacheManager.emptyCache();
    PaintingBinding.instance.imageCache.clear();
  }
}
