import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/welcome_screen.dart';
import 'services/edit_queue_service.dart';
import 'services/osm_auth_service.dart';
import 'services/recent_uploads_service.dart';
import 'services/settings_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // Settings must finish loading before OsmAuthService is constructed: the
  // auth helper reads its base URL from settingsService.osmApiUrl, so we
  // need the persisted override (if any) loaded first.
  final settingsService = SettingsService();
  await settingsService.init();
  runApp(
    SwapBoxMapApp(
      authService: OsmAuthService(settingsService: settingsService),
      settingsService: settingsService,
      editQueueService: EditQueueService(),
      recentUploadsService: RecentUploadsService(),
    ),
  );
}

class SwapBoxMapApp extends StatefulWidget {
  const SwapBoxMapApp({
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

  @override
  State<SwapBoxMapApp> createState() => _SwapBoxMapAppState();
}

class _SwapBoxMapAppState extends State<SwapBoxMapApp> {
  @override
  void initState() {
    super.initState();
    widget.authService.init();
    widget.editQueueService.init();
    widget.recentUploadsService.init();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Swap Box Map',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: AnimatedBuilder(
        animation: Listenable.merge([
          widget.authService,
          widget.settingsService,
          widget.editQueueService,
          widget.recentUploadsService,
        ]),
        builder: (context, _) {
          if (!widget.authService.isInitialized ||
              !widget.settingsService.isInitialized ||
              !widget.editQueueService.isInitialized ||
              !widget.recentUploadsService.isInitialized) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return WelcomeScreen(
            authService: widget.authService,
            settingsService: widget.settingsService,
            editQueueService: widget.editQueueService,
            recentUploadsService: widget.recentUploadsService,
          );
        },
      ),
    );
  }
}
