import 'package:flutter/material.dart';

import '../services/edit_queue_service.dart';
import '../services/osm_auth_service.dart';
import '../services/recent_uploads_service.dart';
import '../services/settings_service.dart';
import 'home_screen.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({
    super.key,
    required this.authService,
    required this.settingsService,
    required this.editQueueService,
    required this.recentUploadsService,
  });

  final OsmAuthService authService;
  final SettingsService settingsService;
  final EditQueueService editQueueService;
  final RecentUploadsService recentUploadsService;

  void _enter(BuildContext context) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => HomeScreen(
          authService: authService,
          settingsService: settingsService,
          editQueueService: editQueueService,
          recentUploadsService: recentUploadsService,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.map_outlined,
                  size: 96,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Swap Box Map',
                  style: theme.textTheme.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'A map of streetside bookcases, give boxes, and community fridges.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: () => _enter(context),
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text("Let's Go"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
