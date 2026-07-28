import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps the WebSocket server alive when the app is not in the foreground.
///
/// Without this, Android suspends the process on backgrounding or screen lock,
/// the listening socket is torn down, and every node silently drops off and
/// starts its reconnect backoff. The persistent notification is the price
/// Android charges for a socket that keeps listening.
///
/// The WiFi lock matters as much as the service itself: on a phone acting as a
/// hotspot, Android will happily doze the WiFi stack.
///
/// Android 15+ caps a `dataSync` foreground service at roughly 6 hours per 24 h
/// and then stops it. A screening session is nowhere near that, but an app left
/// open all day can hit it, so [update] re-starts the service if it finds it
/// gone rather than silently staying dead.
///
/// VERIFY ON A REAL DEVICE -- background behaviour cannot be tested on desktop
/// or in an emulator with any confidence.
class Foreground {
  static bool _initialised = false;

  /// update() is called on every inbound node message; without this the plugin
  /// channel would be hit several times a second during a test.
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
      // Android 13+ will not show the service notification without an explicit
      // grant, and a foreground service with no notification cannot stay in the
      // foreground -- so this permission is what actually keeps nodes connected.
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
        // The system stopped it (Android 15+ dataSync timeout, or the OEM
        // battery manager). Bring it back rather than losing every node.
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
