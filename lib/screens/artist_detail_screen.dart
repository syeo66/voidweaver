import 'package:flutter/material.dart';
import '../services/subsonic_api.dart';
import '../widgets/artist_albums_view.dart';

/// The albums of [artist], opened from the search
class ArtistDetailScreen extends StatelessWidget {
  final Artist artist;

  const ArtistDetailScreen({
    super.key,
    required this.artist,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(artist.name)),
      body: ArtistAlbumsView(artist: artist),
    );
  }
}
