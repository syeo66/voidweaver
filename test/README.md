# Voidweaver Test Suite

This directory contains comprehensive tests for the Voidweaver Flutter music player application.

## Test Structure

### Core Test Files

- **`simple_test.dart`** - Data model tests for Song, Album, Artist, and SearchResult classes
- **`widget_test.dart`** - Basic widget instantiation tests
- **`utils/time_formatter_test.dart`** - Utility function tests including time formatting, ReplayGain parsing, URL validation, and more
- **`utils/validators_test.dart`** - Input validation and sanitization tests with comprehensive security coverage
- **`services/sleep_timer_test.dart`** - Comprehensive sleep timer functionality tests
- **`services/api_cache_test.dart`** - API caching system tests with request deduplication
- **`widgets/error_boundary_test.dart`** - Error boundary and error handling widget tests
- **`services/error_handler_test.dart`** - Global error handler and error reporting tests

### Test Infrastructure

- **`test_helpers/mock_audio_player.dart`** - Mock AudioPlayer implementation for testing
- **`services/sleep_timer_test.mocks.dart`** - Generated mocks for SubsonicApi and SettingsService

## Running Tests

```bash
# Run all tests
flutter test

# Run specific test file
flutter test test/services/sleep_timer_test.dart

# Run tests with coverage
flutter test --coverage

# Run tests with verbose output
flutter test --verbose
```

## Test Coverage

### Current Status: 105/105 Tests Passing ✅

#### Data Models (6 tests)
- Song class construction and equality
- Album class construction and equality  
- Artist class construction and equality
- SearchResult class construction and equality

#### Utility Functions (34 tests)
- Time formatting (minutes:seconds, hours:minutes:seconds)
- ReplayGain value parsing (dB values, malformed inputs)
- URL validation (various formats, edge cases)
- Filename sanitization (illegal characters, Unicode)
- Progress calculation (percentage, edge cases)
- Edge cases and error handling

#### Input Validation (37 tests)
- Server URL validation (protocols, hostnames, lengths)
- Username validation (characters, lengths, sanitization)
- Password validation (security, character limits)
- ReplayGain parameter validation (ranges, numeric formats)
- Input sanitization (control characters, malformed data)
- Security edge cases and attack prevention

#### API Caching (7 tests)  
- Cache storage and retrieval
- Request deduplication
- Cache expiration and invalidation
- Persistent vs memory caching
- Cache statistics and management

#### Sleep Timer (6 tests)
- Timer start functionality
- Timer cancellation
- Timer extension
- Timer completion handling
- Timer replacement
- Invalid operations

#### Error Handling (15 tests)
- Error boundary widget functionality
- Error display components
- Global error handler behavior
- Error reporting infrastructure
- Extension methods for error wrapping
- User recovery and retry mechanisms

## Mock Infrastructure

### MockAudioPlayer

The `MockAudioPlayer` class provides comprehensive mocking of the AudioPlayer plugin:

```dart
// Example usage in tests
setUp(() {
  mockAudioPlayer = MockAudioPlayer();
  audioPlayerService = AudioPlayerService(mockApi, mockSettings, audioPlayer: mockAudioPlayer);
});

// Simulate playback events
mockAudioPlayer.simulateCompletion();
mockAudioPlayer.simulatePositionChange(Duration(seconds: 30));
```

**Features:**
- Stream simulation for position, duration, completion, and state changes
- Playback control mocking (play, pause, stop, seek, volume)
- Helper methods for test scenarios
- Proper resource cleanup

### Generated Mocks

Mock classes are generated using the `mockito` package:

```dart
@GenerateMocks([SubsonicApi, SettingsService])
```

**Available Mocks:**
- `MockSubsonicApi` - API communication mocking
- `MockSettingsService` - Settings management mocking

## Architecture Changes for Testing

### Dependency Injection

The `AudioPlayerService` has been refactored to support dependency injection:

```dart
// Production usage (unchanged)
AudioPlayerService(api, settings) // Uses real AudioPlayer

// Test usage
AudioPlayerService(api, settings, audioPlayer: mockAudioPlayer)
```

**Benefits:**
- Enables reliable testing without plugin dependencies
- Maintains backward compatibility
- Allows comprehensive audio functionality testing
- Eliminates `MissingPluginException` errors in CI/CD

### Test-Friendly Design

- **Optional dependencies** - AudioPlayer is optional parameter with default
- **Stream mocking** - Complete audio stream simulation
- **Resource management** - Proper cleanup in tearDown methods
- **Realistic scenarios** - Tests cover real-world usage patterns

## Adding New Tests

### For New Features

1. **Create test file** in appropriate directory
2. **Set up mocks** using existing infrastructure
3. **Follow naming conventions** - `feature_test.dart`
4. **Use descriptive test names** - `should handle error when server unavailable`

### For Audio Features

```dart
// Template for audio-related tests
setUp(() {
  mockAudioPlayer = MockAudioPlayer();
  audioService = AudioPlayerService(mockApi, mockSettings, audioPlayer: mockAudioPlayer);
});

test('should handle audio feature correctly', () {
  // Test implementation
  mockAudioPlayer.simulateCompletion();
  expect(audioService.someProperty, expectedValue);
});
```

### For API Features

```dart
// Template for API-related tests
setUp(() {
  mockApi = MockSubsonicApi();
  when(mockApi.someMethod()).thenAnswer((_) async => expectedResult);
});

test('should handle API feature correctly', () {
  // Test implementation
});
```

## Test Utilities

### Time Formatting Tests

Comprehensive tests for duration formatting:
- Standard formats (MM:SS, HH:MM:SS)
- Edge cases (zero duration, very long durations)
- Padding behavior

### ReplayGain Tests

Tests for audio normalization value parsing:
- Valid dB values (-20.5 dB, +5.0 dB)
- Values without units
- Malformed inputs
- Extreme values

### URL Validation Tests

Tests for server URL validation:
- HTTP/HTTPS protocols
- Port numbers
- IP addresses
- Invalid formats

## Best Practices

1. **Use descriptive test names** - Clearly state what is being tested
2. **Test edge cases** - Include boundary conditions and error scenarios
3. **Mock external dependencies** - Use provided mock infrastructure
4. **Clean up resources** - Dispose of mocks and services in tearDown
5. **Group related tests** - Use `group()` for logical organization
6. **Assert meaningful values** - Test actual behavior, not just absence of errors

## CI/CD Integration

The test suite is designed for automated testing:
- **No plugin dependencies** - All tests run in any environment
- **Fast execution** - Tests complete in ~6 seconds
- **Comprehensive coverage** - Critical functionality fully tested
- **Zero false positives** - Reliable pass/fail results

## Future Test Additions

Priority areas for additional testing:
1. **Integration tests** - Complete user workflows
2. **Widget tests** - UI component behavior  
3. **Performance tests** - Memory usage, rendering performance
4. **Audio playback tests** - Real audio functionality beyond mocking
5. **Network failure simulation** - More complex error scenarios