import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'subsonic_api.dart';

/// Loads cover art with consistent caching: every image goes through here, so
/// the cache key ([SubsonicApi.coverArtCacheKey]) is the same everywhere.
class ImageCacheManager {
  /// Cover art [coverArtId] of [api]'s server, decoded at the size in
  /// physical pixels when [width] and [height] are given
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
    return Builder(
        key: key,
        builder: (context) {
          final pixelRatio = MediaQuery.devicePixelRatioOf(context);
          return CachedNetworkImage(
            imageUrl: api.getCoverArtUrl(coverArtId),
            width: width,
            height: height,
            fit: fit ?? BoxFit.cover,
            cacheKey: api.coverArtCacheKey(coverArtId),
            placeholder: placeholder ?? (context, url) => _buildPlaceholder(),
            errorWidget: errorWidget ??
                (context, url, error) => _buildErrorWidget(context, url, error),
            memCacheWidth: width == null ? null : (width * pixelRatio).round(),
            memCacheHeight:
                height == null ? null : (height * pixelRatio).round(),
            maxHeightDiskCache: 800, // Limit disk cache size
            maxWidthDiskCache: 800,
            fadeInDuration: const Duration(milliseconds: 200),
            fadeOutDuration: const Duration(milliseconds: 100),
          );
        });
  }

  /// Cover art as an [ImageProvider], e.g. for a [CircleAvatar]
  static ImageProvider coverArtProvider(SubsonicApi api, String coverArtId) {
    return CachedNetworkImageProvider(
      api.getCoverArtUrl(coverArtId),
      cacheKey: api.coverArtCacheKey(coverArtId),
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
