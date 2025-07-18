import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Optimized image cache manager with consistent configuration
class ImageCacheManager {
  /// Create a cached network image with optimized settings
  static Widget buildCachedImage({
    required String imageUrl,
    double? width,
    double? height,
    BoxFit? fit,
    Widget Function(BuildContext, String)? placeholder,
    Widget Function(BuildContext, String, dynamic)? errorWidget,
    String? cacheKey,
  }) {
    return CachedNetworkImage(
      imageUrl: imageUrl,
      width: width,
      height: height,
      fit: fit ?? BoxFit.cover,
      cacheKey: cacheKey,
      placeholder: placeholder ?? (context, url) => _buildPlaceholder(),
      errorWidget: errorWidget ?? (context, url, error) => _buildErrorWidget(context, url, error),
      memCacheWidth: width?.toInt(),
      memCacheHeight: height?.toInt(),
      maxHeightDiskCache: 800, // Limit disk cache size
      maxWidthDiskCache: 800,
      fadeInDuration: const Duration(milliseconds: 200),
      fadeOutDuration: const Duration(milliseconds: 100),
    );
  }

  /// Build album art widget with consistent styling
  static Widget buildAlbumArt({
    required String imageUrl,
    double size = 60,
    String? cacheKey,
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
        child: buildCachedImage(
          imageUrl: imageUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheKey: cacheKey,
        ),
      ),
    );
  }

  /// Build artist avatar widget with consistent styling
  static Widget buildArtistAvatar({
    required String imageUrl,
    required String artistName,
    double size = 60,
    String? cacheKey,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.grey[300],
      ),
      child: ClipOval(
        child: buildCachedImage(
          imageUrl: imageUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheKey: cacheKey,
          errorWidget: (context, url, error) => _buildArtistFallback(artistName, size),
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
  static Widget _buildErrorWidget(BuildContext context, String url, dynamic error) {
    return Container(
      color: Colors.grey[300],
      child: const Icon(
        Icons.music_note,
        color: Colors.grey,
        size: 24,
      ),
    );
  }

  /// Artist fallback widget with initials
  static Widget _buildArtistFallback(String artistName, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.grey[400],
      ),
      child: Center(
        child: Text(
          _getInitials(artistName),
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.3,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  /// Get initials from artist name
  static String _getInitials(String name) {
    if (name.isEmpty) return '?';
    
    final words = name.split(' ');
    if (words.length == 1) {
      return words[0][0].toUpperCase();
    } else {
      return '${words[0][0]}${words[1][0]}'.toUpperCase();
    }
  }

  /// Clear all cached images
  static Future<void> clearCache() async {
    await CachedNetworkImage.evictFromCache('');
  }

  /// Get cache info
  static Map<String, dynamic> getCacheInfo() {
    return {
      'maxHeightDiskCache': 800,
      'maxWidthDiskCache': 800,
      'fadeInDuration': 200,
      'fadeOutDuration': 100,
    };
  }
}