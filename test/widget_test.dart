import 'package:flutter_test/flutter_test.dart';

import 'package:swap_box_map/main.dart';
import 'package:swap_box_map/services/edit_queue_service.dart';
import 'package:swap_box_map/services/osm_auth_service.dart';
import 'package:swap_box_map/services/recent_uploads_service.dart';
import 'package:swap_box_map/services/settings_service.dart';

void main() {
  testWidgets('welcome screen renders Let\'s Go button', (
    WidgetTester tester,
  ) async {
    final settingsService = SettingsService();
    await tester.pumpWidget(
      SwapBoxMapApp(
        authService: OsmAuthService(settingsService: settingsService),
        settingsService: settingsService,
        editQueueService: EditQueueService(),
        recentUploadsService: RecentUploadsService(),
      ),
    );
    await tester.pump();

    expect(find.text("Let's Go"), findsOneWidget);
  });
}
