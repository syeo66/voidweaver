# Voidweaver Flutter Project Makefile
.PHONY: help setup analyze format test test-android test-integration check-apk check-emulator check-emulator-fake build-release clean doctor devices run install upgrade

# Default target
all: format analyze test

# Help target
help:
	@echo "Available targets:"
	@echo "  setup         - Ensure Flutter is installed and get dependencies"
	@echo "  analyze       - Run static analysis (dart analyze)"
	@echo "  format        - Format code (dart format)"
	@echo "  test          - Run the Dart tests (app and player plugin)"
	@echo "  test-android  - Run the player plugin's JVM tests (Gradle, needs JAVA_HOME)"
	@echo "  test-integration - Run the user-flow tests on a device/emulator (fake server, debug build)"
	@echo "  check-apk     - Check the release APK for shrunk-away notification resources and session entries"
	@echo "  check-emulator - Check media session, media keys and resumption in the running emulator"
	@echo "  check-emulator-fake - The same against the fake server, no login needed (fresh app data)"
	@echo "  build-release - Build release APK (includes format, analyze, test)"
	@echo "  clean         - Clean build artifacts"
	@echo "  doctor        - Check Flutter installation"
	@echo "  devices       - List available devices"
	@echo "  run           - Run app on connected device/emulator"
	@echo "  install       - Install dependencies"
	@echo "  upgrade       - Upgrade dependencies"

# Setup target - ensures Flutter is available and dependencies are installed
setup:
	@echo "Checking Flutter installation..."
	@which flutter > /dev/null || (echo "Flutter not found. Please install Flutter first." && exit 1)
	@echo "Getting Flutter dependencies..."
	flutter pub get
	@echo "Setup complete."

# Install dependencies
install: setup

# Upgrade dependencies
upgrade:
	@echo "Upgrading Flutter dependencies..."
	flutter pub upgrade

# Format code
format: setup
	@echo "Formatting Dart code..."
	dart format lib/ test/ integration_test/ packages/voidweaver_player/lib/ packages/voidweaver_player/test/
	@echo "Code formatting complete."

# Static analysis
analyze: setup
	@echo "Running static analysis..."
	flutter analyze
	@echo "Static analysis complete."

# Run tests
test: setup
	@echo "Running tests..."
	flutter test
	cd packages/voidweaver_player && flutter test
	@echo "Tests complete."

# JVM tests of the player plugin's Java code (Robolectric)
test-android: setup
	@echo "Running Android unit tests..."
	cd android && ./gradlew :voidweaver_player:testDebugUnitTest
	@echo "Android unit tests complete."

# User flows on a device or emulator, against the fake Subsonic server
# running in the app (integration_test/, debug build)
test-integration: setup
	@echo "Running integration tests..."
	flutter test integration_test
	@echo "Integration tests complete."

# System integration of the release build in the running emulator
# (tool/emulator_check.sh: media session, notification, media keys, resumption)
check-emulator: setup
	flutter build apk --release
	tool/check_release_apk.sh
	tool/emulator_check.sh

# The same checks without a real server or login: a release build that
# trusts the tests' fake Subsonic server, which runs on this machine
# (tool/emulator_check.sh --fake-server). Clears the app's data.
check-emulator-fake: setup
	tool/emulator_check.sh --fake-server --build

# What R8 and the resource shrinker can break in the release APK, without a
# device (tool/check_release_apk.sh: notification icons, manifest, classes)
check-apk: setup
	flutter build apk --release
	tool/check_release_apk.sh

# Build release APK with full validation
build-release: format analyze test
	@echo "Building release APK..."
	flutter build apk --release
	tool/check_release_apk.sh
	@echo "Release APK built successfully."
	@echo "APK location: build/app/outputs/flutter-apk/app-release.apk"

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	flutter clean
	@echo "Clean complete."

# Check Flutter installation
doctor:
	@echo "Checking Flutter doctor..."
	flutter doctor

# List available devices
devices:
	@echo "Available devices:"
	flutter devices

# Run app on connected device/emulator
run: setup
	@echo "Running app..."
	flutter run
