import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/network_errors.dart';
import '../utils/validators.dart';

/// Shown while the server rejects the saved credentials
/// ([AppState.credentialsRejected]), e.g. after the password was changed on
/// the server. Offers to enter the new password, which keeps the pending
/// plays, unlike logging out.
class CredentialsBanner extends StatelessWidget {
  const CredentialsBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final rejected =
        context.select<AppState, bool>((state) => state.credentialsRejected);
    if (!rejected) return const SizedBox.shrink();

    final colors = Theme.of(context).colorScheme;
    return MaterialBanner(
      backgroundColor: colors.errorContainer,
      leading: Icon(Icons.lock_outline, color: colors.onErrorContainer),
      content: Text(
        'The server doesn\'t accept the saved password anymore. '
        'Plays are kept until it does.',
        style: TextStyle(color: colors.onErrorContainer),
      ),
      actions: [
        TextButton(
          onPressed: () => unawaited(showDialog<void>(
            context: context,
            builder: (context) => const UpdatePasswordDialog(),
          )),
          child: const Text('Update password'),
        ),
      ],
    );
  }
}

/// Asks for the new password and logs in again with it
/// ([AppState.updatePassword]). Stays open, showing the error, until the
/// server accepts it.
class UpdatePasswordDialog extends StatefulWidget {
  const UpdatePasswordDialog({super.key});

  @override
  State<UpdatePasswordDialog> createState() => _UpdatePasswordDialogState();
}

class _UpdatePasswordDialogState extends State<UpdatePasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _controller = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final appState = context.read<AppState>();
    try {
      // Not trimmed: spaces at either end can be part of a password
      await appState.updatePassword(_controller.text);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = NetworkErrorHelper.getErrorMessage(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final username = context.read<AppState>().api?.username;
    return AlertDialog(
      title: const Text('Update password'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (username != null) Text('New password for $username'),
            const SizedBox(height: 16),
            TextFormField(
              controller: _controller,
              // Not disabled, which would take the focus and close the
              // keyboard, so a rejected password can be corrected right away
              readOnly: _saving,
              autofocus: true,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Password',
                border: const OutlineInputBorder(),
                errorText: _error,
                errorMaxLines: 3,
              ),
              validator: Validators.validatePassword,
              onFieldSubmitted: (_) => unawaited(_save()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _saving ? null : () => unawaited(_save()),
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Update'),
        ),
      ],
    );
  }
}
