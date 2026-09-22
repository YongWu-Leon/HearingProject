import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps the WebSocket server alive when the app is backgrounded.
///
/// Without a foreground service, Android suspends the process and every node
/// drops off. The WiFi lock is needed too, or Android dozes the hotspot's WiFi
/// stack. Android 15+ caps a `dataSync` service at ~6h/24h, so [update]
/// restarts the service if it finds it stopped.
///
/// Verify on a real device -- not testable on desktop/emulator.
class Foreground {
  static bool _initialised = false;

  /// Throttles update(), which is called on every inbound node message.
  static DateTime _lastCheck = DateTime.fromMillisecondsSinceEpoch(0);
  static const _checkEvery = Duration(seconds: 10);

  static Future<void> init() async {
    if (_initialised) return;
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'hearing_hub',
          channelName: 'Hearing test hub',
          channelDescription:
              'Keeps the test server reachable while the app is in the background.',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          autoRunOnBoot: false,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );
      _initialised = true;
    } catch (e) {
      debugPrint('[fg] init failed: $e');
    }
  }

  static Future<void> start({required int nodeCount}) async {
    await init();
    try {
      // Android 13+ needs an explicit grant to show the service notification.
      final permission = await FlutterForegroundTask.checkNotificationPermission();
      if (permission != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }

      if (await FlutterForegroundTask.isRunningService) {
        await update(nodeCount: nodeCount);
        return;
      }
      await FlutterForegroundTask.startService(
        notificationTitle: 'Hearing hub running',
        notificationText: '$nodeCount node(s) connected',
      );
    } catch (e) {
      debugPrint('[fg] start failed: $e');
    }
  }

  static Future<void> update({required int nodeCount}) async {
    final now = DateTime.now();
    if (now.difference(_lastCheck) < _checkEvery) return;
    _lastCheck = now;
    try {
      if (!await FlutterForegroundTask.isRunningService) {
        // System stopped it (dataSync timeout or OEM battery manager); restart.
        debugPrint('[fg] service was stopped by the system, restarting');
        await start(nodeCount: nodeCount);
        return;
      }
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Hearing hub running',
        notificationText: '$nodeCount node(s) connected',
      );
    } catch (e) {
      debugPrint('[fg] update failed: $e');
    }
  }

  static Future<void> stop() async {
    try {
      await FlutterForegroundTask.stopService();
    } catch (e) {
      debugPrint('[fg] stop failed: $e');
    }
  }
}
