import 'package:flutter/material.dart';
import 'push_controller.dart';

class PushSettings extends StatelessWidget {
  const PushSettings({super.key, required this.controller});
  final PushController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final state = controller.state;
      final denied = state.permission == 'denied';
      final available =
          state.supported && controller.configuration?.enabled == true;
      final status = !controller.ready
          ? 'Checking notification support…'
          : !state.supported
          ? 'Notifications are unavailable in this browser.'
          : denied
          ? 'Notifications are blocked. Allow them in your browser’s site settings, then retry.'
          : state.storageFull
          ? 'Notifications are paused while this browser retains recent delivery records. Try again later.'
          : controller.enabled
          ? 'Message notifications are on for this browser.'
          : !available && controller.error == null
          ? 'Message notifications are not available yet.'
          : 'Receive a general notification when a new message arrives.';
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Message notifications',
              style: TextStyle(fontSize: 13, color: Color(0xFF14679E)),
            ),
            const SizedBox(height: 8),
            Text(
              status,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
            if (controller.error != null)
              Text(
                controller.error!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12),
              ),
            if (controller.ready && state.supported)
              TextButton(
                key: const Key('push-settings-action'),
                onPressed: controller.busy
                    ? null
                    : controller.enabled
                    ? controller.disable
                    : denied || !available || controller.error != null
                    ? controller.refresh
                    : controller.enable,
                child: Text(
                  controller.busy
                      ? 'Updating…'
                      : controller.enabled
                      ? 'Turn off notifications'
                      : denied || !available || controller.error != null
                      ? 'Retry notifications'
                      : 'Enable notifications',
                ),
              ),
          ],
        ),
      );
    },
  );
}
