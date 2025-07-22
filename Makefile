# Voidweaver Flutter Project Makefile
.PHONY: help setup analyze format test build-release clean doctor devices run run-web install upgrade

# Default target
all: format analyze test

# Help target
help:
	@echo "Available targets:"
	@echo "  setup         - Ensure Flutter is installed and get dependencies"
	@echo "  analyze       - Run static analysis (dart analyze)"
	@echo "  format        - Format code (dart format)"
	@echo "  test          - Run all tests"
	@echo "  build-release - Build release APK (includes format, analyze, test)"
	@echo "  clean         - Clean build artifacts"
	@echo "  doctor        - Check Flutter installation"
	@echo "  devices       - List available devices"
	@echo "  run           - Run app on connected device/emulator"
	@echo "  run-web       - Run app in web browser"
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
	dart format lib/ test/
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
	@echo "Tests complete."

# Build release APK with full validation
build-release: format analyze test
	@echo "Building release APK..."
	flutter build apk --release
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

# Run app in web browser
run-web: setup
	@echo "Running app in web browser..."
	flutter run -d chrome