import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/settings_service.dart';
import 'package:voidweaver/models/album_list_type.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('album list type', () {
    test('defaults to recently played', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();
      await settings.initialize();

      expect(settings.albumListType, AlbumListType.recent);
    });

    test('is saved', () async {
      SharedPreferences.setMockInitialValues({});
      final saved = SettingsService();
      await saved.initialize();
      await saved.setAlbumListType(AlbumListType.newest);
      final settings = SettingsService();
      await settings.initialize();

      expect(settings.albumListType, AlbumListType.newest);
    });

    test('falls back to recently played for an unknown value', () async {
      SharedPreferences.setMockInitialValues({'albumListType': 'frequent'});
      final settings = SettingsService();
      await settings.initialize();

      expect(settings.albumListType, AlbumListType.recent);
    });
  });

  group('stored values that can\'t be used', () {
    test('an index outside the enum gives the default', () async {
      SharedPreferences.setMockInitialValues({
        'replayGainMode': 99,
        'themeMode': -1,
      });
      final settings = SettingsService();
      await settings.initialize();

      expect(settings.replayGainMode, ReplayGainMode.off);
      expect(settings.themeMode, ThemeMode.system);
    });

    test('a value of another type gives the default', () async {
      SharedPreferences.setMockInitialValues({
        'replayGainMode': 'smart',
        'themeMode': 'dark',
        'replayGainPreamp': 'loud',
        'replayGainPreventClipping': 1,
        'scrobbleThresholdPercent': true,
        'albumListType': 3,
        'networkConfig': 5,
      });
      final settings = SettingsService();
      await settings.initialize();

      expect(settings.replayGainMode, ReplayGainMode.off);
      expect(settings.themeMode, ThemeMode.system);
      expect(settings.replayGainPreamp, 0.0);
      expect(settings.replayGainPreventClipping, isTrue);
      expect(settings.scrobbleThresholdPercent, 50.0);
      expect(settings.albumListType, AlbumListType.recent);
    });

    test('valid values next to a bad one are still loaded', () async {
      SharedPreferences.setMockInitialValues({
        'replayGainMode': 99,
        'themeMode': ThemeMode.dark.index,
        'replayGainPreamp': 3.0,
      });
      final settings = SettingsService();
      await settings.initialize();

      expect(settings.themeMode, ThemeMode.dark);
      expect(settings.replayGainPreamp, 3.0);
    });
  });
}
