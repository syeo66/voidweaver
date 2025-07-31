# Error Handling System

Voidweaver implements a comprehensive error boundary system that prevents app crashes and provides graceful error recovery throughout the application.

## Overview

The error handling system consists of three main components:

1. **Global Error Handler** - Catches uncaught exceptions app-wide
2. **Error Boundary Widgets** - Protects individual UI components
3. **Error Reporting Infrastructure** - Logs and tracks errors for debugging

## Architecture

### Global Error Handler

The `ErrorHandler` service is initialized at app startup and catches:

- Flutter framework errors
- Platform errors (Isolate errors)
- Uncaught async errors
- Zone errors

```dart
// Initialized in main.dart
ErrorHandler.instance.initialize();
ErrorHandler.instance.addReporter(ConsoleErrorReporter());
```

### Error Boundary Widgets

#### ErrorBoundary

Wraps widgets to catch build-time and widget-level errors:

```dart
ErrorBoundary(
  errorMessage: 'Failed to load this section',
  onError: (error) => print('Error caught: $error'),
  child: YourWidget(),
)
```

#### AsyncErrorBoundary

Specialized for async operations with retry functionality:

```dart
AsyncErrorBoundary(
  errorMessage: 'Failed to load data',
  onRetry: () async => await loadData(),
  child: DataWidget(),
)
```

#### Extension Methods

Convenient extension methods for quick error wrapping:

```dart
// Basic error boundary
Widget().withErrorBoundary(
  errorMessage: 'Something went wrong',
)

// Async error boundary with retry
Widget().withAsyncErrorBoundary(
  errorMessage: 'Failed to load',
  onRetry: () async => await retryOperation(),
)
```

## Components

### ErrorDisplay Widget

Shows user-friendly error information:

- Error icon and title
- Custom error message
- Retry button (when onRetry provided)
- Report button (when onReport provided)
- Expandable error details (debug mode only)

### Error Reporters

#### ConsoleErrorReporter
- Logs errors to console in debug mode
- Includes timestamp, error details, and stack traces

#### MemoryErrorReporter
- Stores recent errors in memory for debugging
- Configurable maximum error count
- Provides `ErrorLogViewer` widget for displaying error history

## Implementation Details

### App Integration

The error boundary system is integrated throughout the app:

#### Main App Level
```dart
// main.dart - Global error handling
runZonedGuarded(
  () => runApp(MyApp()),
  (error, stackTrace) => ErrorHandler.instance.reportError(error, stackTrace),
);

// App wrapped with error boundary
ErrorBoundary(
  errorMessage: 'The app encountered a critical error',
  child: MaterialApp(...),
)
```

#### Screen Level
```dart
// Home screen sections protected
IndexedStack(
  children: [
    AlbumList().withErrorBoundary(
      errorMessage: 'Failed to load albums',
    ),
    ArtistScreen().withErrorBoundary(
      errorMessage: 'Failed to load artists',
    ),
  ],
)
```

#### Component Level
```dart
// Player controls protected
PlayerControls().withErrorBoundary(
  errorMessage: 'Player controls encountered an error',
)
```

### Error Recovery

The system provides multiple recovery mechanisms:

1. **Retry Buttons** - Allow users to retry failed operations
2. **Fallback UI** - Shows helpful error messages instead of crashes
3. **Graceful Degradation** - App continues functioning even when components fail
4. **Component Isolation** - Errors in one component don't affect others

## Testing

The error boundary system includes comprehensive tests:

### Widget Tests (9 tests)
- Error boundary creation and display
- Child widget rendering when no errors occur
- Error UI display with proper messages and icons
- Retry functionality validation
- Extension method behavior verification

### Service Tests (6 tests)
- Error handler singleton behavior
- Error reporter functionality
- Memory error storage and limits
- Error record formatting and display

### Test Files
- `test/widgets/error_boundary_test.dart` - Widget-level error handling tests
- `test/services/error_handler_test.dart` - Service-level error handling tests

## Usage Guidelines

### When to Use Error Boundaries

✅ **Do use error boundaries for:**
- Screen-level components that could fail independently
- Network-dependent widgets (API calls, image loading)
- Complex widgets with multiple failure points
- User input forms and validation
- Audio playback controls and media widgets

❌ **Don't use error boundaries for:**
- Simple text or icon widgets
- Already well-tested core Flutter widgets
- Components where errors should bubble up to parent handlers

### Best Practices

1. **Wrap at appropriate levels** - Don't over-wrap simple components
2. **Provide meaningful error messages** - Help users understand what went wrong
3. **Implement retry logic** - Give users a way to recover from errors
4. **Log errors for debugging** - Use error reporters to track issues
5. **Test error scenarios** - Verify error boundaries work as expected

### Error Message Guidelines

- Be specific about what failed: "Failed to load albums" vs "Something went wrong"
- Provide actionable guidance: "Please check your connection and try again"
- Keep messages user-friendly and non-technical
- Include retry options when possible

### HTTPS Security Validation Errors

The app enforces HTTPS connections for security and provides clear error messages for HTTP attempts:

#### URL Validation Errors
- **HTTP URLs rejected**: "URL must use HTTPS protocol for security"
- **Invalid URLs**: "Please enter a valid URL (e.g., https://music.example.com)"
- **Missing hostname**: "URL must include a hostname"

#### API Constructor Errors
- **SubsonicApi HTTPS check**: `ArgumentError('Server URL must use HTTPS protocol for security')`
- **Malformed URLs**: Rejected during URI parsing with clear error messages

#### User Interface Feedback
- **Login form indicators**: Clear HTTPS requirement with lock icon and helper text
- **Connection troubleshooting**: Updated guidance emphasizing HTTPS requirement
- **Real-time validation**: Immediate feedback during URL entry

These security-focused error messages help users understand the HTTPS requirement while protecting credentials and music data in transit.

## Debugging

### Error Log Viewer

In debug mode, you can view recent errors:

```dart
// Show error log dialog
showDialog(
  context: context,
  builder: (context) => ErrorLogViewer(
    reporter: memoryErrorReporter,
  ),
);
```

### Console Output

Errors are automatically logged to console with full details:

```
=== ERROR REPORT ===
Time: 2024-01-15 10:30:45
Error: Exception: Network request failed
Stack trace:
  #0  SubsonicApi._makeRequest
  #1  SubsonicApi.getAlbums
  ...
Context: Album loading operation
==================
```

## Future Enhancements

Potential improvements to the error handling system:

- **Remote error reporting** - Send errors to analytics service
- **Error categorization** - Group similar errors for better insights  
- **User feedback integration** - Allow users to report bugs directly
- **Performance monitoring** - Track error impact on app performance
- **Smart retry logic** - Implement exponential backoff for network errors

## Related Documentation

- [Development Guide](DEVELOPMENT.md) - Overall app architecture
- [Testing Documentation](../test/README.md) - Test suite information
- [Architecture Overview](DEVELOPMENT.md#architecture) - App structure details