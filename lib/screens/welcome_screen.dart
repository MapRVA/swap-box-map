import 'package:flutter/material.dart';

import '../services/settings_service.dart';

/// First-run greeting. Tapping "Let's Go" flips [SettingsService.welcomeSeen],
/// which causes the root `AnimatedBuilder` in `main.dart` to swap this screen
/// out for `HomeScreen`. We deliberately do not navigate here: keeping the
/// root builder in control lets `SettingsService.resetWelcomeSeen()` surface
/// the welcome screen again later without route juggling.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key, required this.settingsService});

  final SettingsService settingsService;

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
                  onPressed: settingsService.markWelcomeSeen,
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
