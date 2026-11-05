import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../widgets/credentials_banner.dart';
import '../widgets/album_list.dart';
import '../widgets/now_playing_view.dart';
import '../widgets/player_controls.dart';
import '../widgets/sleep_timer_dialog.dart';
import '../widgets/sync_status_indicator.dart';
import '../widgets/error_boundary.dart';
import 'settings_screen.dart';
import 'search_screen.dart';
import 'artist_screen.dart';
import '../services/network_errors.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const int _nowPlayingTabIndex = 2;

  int _currentIndex = 0;
  bool _isPlayingRandomSongs = false;

  // Incremented whenever the 'Now Playing' tab is tapped so the playlist
  // scrolls to the current track, even if the tab is already selected.
  final ValueNotifier<int> _scrollToCurrentTrackRequest = ValueNotifier(0);

  @override
  void dispose() {
    _scrollToCurrentTrackRequest.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voidweaver'),
        actions: [
          const SyncStatusIndicator(),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (context) => const SearchScreen()),
              );
            },
          ),
          IconButton(
            icon: _isPlayingRandomSongs
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.shuffle),
            tooltip: 'Play random songs',
            onPressed: _isPlayingRandomSongs
                ? null
                : () async {
                    setState(() => _isPlayingRandomSongs = true);

                    final appState = context.read<AppState>();
                    final messenger = ScaffoldMessenger.of(context);
                    final errorColor = Theme.of(context).colorScheme.error;

                    try {
                      await appState.audioPlayerService?.playRandomSongs();
                    } catch (e) {
                      if (mounted) {
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(
                              NetworkErrorHelper.getErrorMessage(
                                e,
                                context: 'Failed to play random songs',
                              ),
                            ),
                            backgroundColor: errorColor,
                          ),
                        );
                      }
                    } finally {
                      if (mounted) {
                        setState(() => _isPlayingRandomSongs = false);
                      }
                    }
                  },
          ),
          Consumer<AppState>(
            builder: (context, appState, child) {
              if (appState.audioPlayerService == null ||
                  !appState.isConfigured) {
                return const SizedBox(width: 0, height: 0);
              }
              return ListenableBuilder(
                listenable: appState.audioPlayerService!,
                builder: (context, child) {
                  return IconButton(
                    icon: appState.audioPlayerService!.isSleepTimerActive
                        ? const Icon(Icons.bedtime, color: Colors.orange)
                        : const Icon(Icons.bedtime_outlined),
                    tooltip: 'Sleep timer',
                    onPressed: () => unawaited(
                      showSleepTimerDialog(
                        context,
                        appState.audioPlayerService!,
                      ),
                    ),
                  );
                },
              );
            },
          ),
          PopupMenuButton(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'logout') {
                unawaited(_confirmLogout());
              } else if (value == 'settings') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const SettingsScreen(),
                  ),
                );
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.settings),
                    SizedBox(width: 8),
                    Text('Settings'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout),
                    SizedBox(width: 8),
                    Text('Logout'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          const CredentialsBanner(),
          Expanded(
            child: IndexedStack(
              index: _currentIndex,
              children: [
                const AlbumList().withErrorBoundary(
                  errorMessage: 'Failed to load albums. Please try refreshing.',
                ),
                const ArtistScreen().withErrorBoundary(
                  errorMessage:
                      'Failed to load artists. Please try refreshing.',
                ),
                ErrorBoundary(
                  errorMessage: 'Failed to load now playing screen.',
                  child: _buildNowPlayingScreen(),
                ),
              ],
            ),
          ),
          Consumer<AppState>(
            builder: (context, appState, child) {
              if (appState.audioPlayerService == null) {
                return const SizedBox.shrink();
              }
              return ChangeNotifierProvider.value(
                value: appState.audioPlayerService!,
                child: const PlayerControls().withErrorBoundary(
                  errorMessage: 'Player controls encountered an error.',
                ),
              );
            },
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
          if (index == _nowPlayingTabIndex) {
            _scrollToCurrentTrackRequest.value++;
          }
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.library_music),
            label: 'Albums',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Artists'),
          BottomNavigationBarItem(
            icon: Icon(Icons.music_note),
            label: 'Now Playing',
          ),
        ],
      ),
    );
  }

  /// Asks before logging out, which removes the credentials and the server's
  /// data, including plays that haven't been scrobbled yet.
  Future<void> _confirmLogout() async {
    final appState = context.read<AppState>();
    final pending = appState.pendingScrobbles;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Log out?'),
        content: Text(
          [
            'You will have to log in again. Settings are kept.',
            if (pending == 1)
              '1 play hasn\'t been sent to the server yet and will be lost.'
            else if (pending > 1)
              '$pending plays haven\'t been sent to the server yet and will be lost.',
          ].join('\n\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await appState.clearConfiguration();
  }

  Widget _buildNowPlayingScreen() {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        if (appState.audioPlayerService == null) {
          return const Center(child: Text('No audio player available'));
        }

        return ChangeNotifierProvider.value(
          value: appState.audioPlayerService!,
          child: NowPlayingView(
            appState: appState,
            scrollToCurrentTrackRequest: _scrollToCurrentTrackRequest,
          ),
        );
      },
    );
  }
}
