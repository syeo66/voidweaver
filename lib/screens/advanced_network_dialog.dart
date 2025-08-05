import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../services/network_config.dart';

class AdvancedNetworkSettingsDialog extends StatefulWidget {
  final SettingsService settingsService;

  const AdvancedNetworkSettingsDialog({
    super.key,
    required this.settingsService,
  });

  @override
  State<AdvancedNetworkSettingsDialog> createState() =>
      _AdvancedNetworkSettingsDialogState();
}

class _AdvancedNetworkSettingsDialogState
    extends State<AdvancedNetworkSettingsDialog> {
  late TextEditingController _connectionTimeoutController;
  late TextEditingController _requestTimeoutController;
  late TextEditingController _metadataTimeoutController;
  late TextEditingController _streamingTimeoutController;
  late TextEditingController _maxRetriesController;
  late bool _enableRetryOnTimeout;
  late bool _enableRetryOnConnectionError;

  @override
  void initState() {
    super.initState();
    final config = widget.settingsService.networkConfig;

    _connectionTimeoutController = TextEditingController(
      text: config.connectionTimeout.inSeconds.toString(),
    );
    _requestTimeoutController = TextEditingController(
      text: config.requestTimeout.inSeconds.toString(),
    );
    _metadataTimeoutController = TextEditingController(
      text: config.metadataTimeout.inSeconds.toString(),
    );
    _streamingTimeoutController = TextEditingController(
      text: config.streamingTimeout.inSeconds.toString(),
    );
    _maxRetriesController = TextEditingController(
      text: config.maxRetryAttempts.toString(),
    );
    _enableRetryOnTimeout = config.enableRetryOnTimeout;
    _enableRetryOnConnectionError = config.enableRetryOnConnectionError;
  }

  @override
  void dispose() {
    _connectionTimeoutController.dispose();
    _requestTimeoutController.dispose();
    _metadataTimeoutController.dispose();
    _streamingTimeoutController.dispose();
    _maxRetriesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Advanced Network Settings'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildTimeoutField(
                'Connection Timeout (seconds)',
                _connectionTimeoutController,
                'Time to wait for initial connection',
              ),
              const SizedBox(height: 16),
              _buildTimeoutField(
                'Request Timeout (seconds)',
                _requestTimeoutController,
                'Maximum time for any request to complete',
              ),
              const SizedBox(height: 16),
              _buildTimeoutField(
                'Metadata Timeout (seconds)',
                _metadataTimeoutController,
                'Timeout for album/artist information requests',
              ),
              const SizedBox(height: 16),
              _buildTimeoutField(
                'Streaming Timeout (seconds)',
                _streamingTimeoutController,
                'Timeout for audio streaming requests',
              ),
              const SizedBox(height: 16),
              _buildTimeoutField(
                'Max Retry Attempts',
                _maxRetriesController,
                'Number of times to retry failed requests',
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                title: const Text('Retry on Timeout'),
                subtitle:
                    const Text('Automatically retry requests that time out'),
                value: _enableRetryOnTimeout,
                onChanged: (value) {
                  setState(() {
                    _enableRetryOnTimeout = value;
                  });
                },
              ),
              SwitchListTile(
                title: const Text('Retry on Connection Error'),
                subtitle: const Text('Automatically retry connection failures'),
                value: _enableRetryOnConnectionError,
                onChanged: (value) {
                  setState(() {
                    _enableRetryOnConnectionError = value;
                  });
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _resetToDefaults,
          child: const Text('Reset to Defaults'),
        ),
        ElevatedButton(
          onPressed: _saveSettings,
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _buildTimeoutField(
      String label, TextEditingController controller, String hint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: hint,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ],
    );
  }

  void _resetToDefaults() {
    const defaultConfig = NetworkConfig.defaultConfig;
    setState(() {
      _connectionTimeoutController.text =
          defaultConfig.connectionTimeout.inSeconds.toString();
      _requestTimeoutController.text =
          defaultConfig.requestTimeout.inSeconds.toString();
      _metadataTimeoutController.text =
          defaultConfig.metadataTimeout.inSeconds.toString();
      _streamingTimeoutController.text =
          defaultConfig.streamingTimeout.inSeconds.toString();
      _maxRetriesController.text = defaultConfig.maxRetryAttempts.toString();
      _enableRetryOnTimeout = defaultConfig.enableRetryOnTimeout;
      _enableRetryOnConnectionError =
          defaultConfig.enableRetryOnConnectionError;
    });
  }

  void _saveSettings() async {
    try {
      final connectionTimeout = int.parse(_connectionTimeoutController.text);
      final requestTimeout = int.parse(_requestTimeoutController.text);
      final metadataTimeout = int.parse(_metadataTimeoutController.text);
      final streamingTimeout = int.parse(_streamingTimeoutController.text);
      final maxRetries = int.parse(_maxRetriesController.text);

      // Validate inputs
      if (connectionTimeout < 1 || connectionTimeout > 300) {
        _showError('Connection timeout must be between 1 and 300 seconds');
        return;
      }
      if (requestTimeout < 1 || requestTimeout > 600) {
        _showError('Request timeout must be between 1 and 600 seconds');
        return;
      }
      if (metadataTimeout < 1 || metadataTimeout > 300) {
        _showError('Metadata timeout must be between 1 and 300 seconds');
        return;
      }
      if (streamingTimeout < 1 || streamingTimeout > 1200) {
        _showError('Streaming timeout must be between 1 and 1200 seconds');
        return;
      }
      if (maxRetries < 0 || maxRetries > 10) {
        _showError('Max retries must be between 0 and 10');
        return;
      }

      // Create new config
      final newConfig = NetworkConfig(
        connectionTimeout: Duration(seconds: connectionTimeout),
        requestTimeout: Duration(seconds: requestTimeout),
        metadataTimeout: Duration(seconds: metadataTimeout),
        streamingTimeout: Duration(seconds: streamingTimeout),
        maxRetryAttempts: maxRetries,
        enableRetryOnTimeout: _enableRetryOnTimeout,
        enableRetryOnConnectionError: _enableRetryOnConnectionError,
      );

      await widget.settingsService.setNetworkConfig(newConfig);

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Network settings saved successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      _showError('Invalid input: Please enter valid numbers');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }
}
