import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.settingsService});

  final SettingsService settingsService;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _overpassController;

  @override
  void initState() {
    super.initState();
    _overpassController = TextEditingController(
      text: widget.settingsService.overpassUrl,
    );
  }

  @override
  void dispose() {
    _overpassController.dispose();
    super.dispose();
  }

  String? _validateUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        (!uri.isScheme('http') && !uri.isScheme('https'))) {
      return 'Enter a valid http(s) URL.';
    }
    return null;
  }

  Future<void> _saveOverpass() async {
    final value = _overpassController.text.trim();
    final error = _validateUrl(value);
    final messenger = ScaffoldMessenger.of(context);
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    await widget.settingsService.setOverpassUrl(value);
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Overpass endpoint saved.')),
    );
  }

  Future<void> _resetOverpass() async {
    final messenger = ScaffoldMessenger.of(context);
    await widget.settingsService.setOverpassUrl(null);
    if (!mounted) return;
    _overpassController.text = widget.settingsService.overpassUrl;
    messenger.showSnackBar(
      const SnackBar(content: Text('Reset to default endpoint.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Overpass Endpoint', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Overpass API server used to load data from OpenStreetMap.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _overpassController,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'URL',
              helperText:
                  'Default: ${widget.settingsService.defaultOverpassUrl}',
              helperMaxLines: 2,
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton(onPressed: _saveOverpass, child: const Text('Save')),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _resetOverpass,
                child: const Text('Reset to default'),
              ),
            ],
          ),
          const SizedBox(height: 32),
          Text('Location', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Used to show your position on the map and to verify POIs you visit in person.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.location_on_outlined),
            title: const Text('Manage location permission'),
            subtitle: const Text("Opens this app's system settings page."),
            trailing: const Icon(Icons.open_in_new, size: 16),
            onTap: () => Geolocator.openAppSettings(),
          ),
        ],
      ),
    );
  }
}
