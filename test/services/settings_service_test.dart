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
}
