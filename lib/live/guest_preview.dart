import 'package:flutter/material.dart';

import '../app.dart';
import '../demo_contacts.dart';
import '../profile/demo_profile.dart';
import '../profile/public_profile_view.dart';
import '../profile/user_profile.dart';

/// Read-only sample data, independent of membership and onboarding storage.
class GuestPreview extends StatefulWidget {
  const GuestPreview({super.key, required this.onRequireSignIn});
  final VoidCallback onRequireSignIn;

  @override
  State<GuestPreview> createState() => _GuestPreviewState();
}

class _GuestPreviewState extends State<GuestPreview> {
  late Future<UserProfile> _paul = loadDemoProfile();

  void _open(UserProfile profile, Widget avatar) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Banner(
        message: 'Preview',
        location: BannerLocation.topEnd,
        color: const Color(0xFF14679E),
        child: PublicProfileView(
          profile: profile,
          avatar: avatar,
          onChat: widget.onRequireSignIn,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 402),
          child: Padding(
            padding: const EdgeInsets.only(top: 60),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: ProfileNavigation(
                    selected: 0,
                    enabledTabs: const {0, 2, 3},
                    onSelected: (index) {
                      if (index != 0) widget.onRequireSignIn();
                    },
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(37.5, 24, 37.5, 0),
                  child: Text(
                    'Preview · Demonstration profiles',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ),
                Expanded(
                  child: FutureBuilder<UserProfile>(
                    future: _paul,
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return Center(
                          child: TextButton(
                            onPressed: () =>
                                setState(() => _paul = loadDemoProfile()),
                            child: const Text('Retry preview profiles'),
                          ),
                        );
                      }
                      final paul = snapshot.data;
                      if (paul == null) {
                        return const Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        );
                      }
                      return Stack(
                        children: [
                          ListView(
                            key: const Key('guest-contacts'),
                            padding: const EdgeInsets.fromLTRB(
                              37.5,
                              24,
                              37.5,
                              88,
                            ),
                            children: [
                              ContactRow(
                                name: paul.name,
                                occupation: paul.occupation,
                                avatar: ProfileAvatar(
                                  photo: paul.photo,
                                  size: 65,
                                ),
                                onOpen: () => _open(
                                  paul,
                                  ProfileAvatar(photo: paul.photo, size: 144),
                                ),
                              ),
                              ContactRow(
                                name: demoChatContact.name,
                                occupation: demoChatContact.occupation,
                                avatar: ProfileAvatar(
                                  asset: demoChatContact.photoAsset,
                                  size: 65,
                                ),
                                onOpen: () => _open(
                                  demoChatContact.profile,
                                  ProfileAvatar(
                                    asset: demoChatContact.photoAsset,
                                    size: 144,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          Positioned(
                            right: 28,
                            bottom: 24,
                            child: FloatingActionButton.small(
                              tooltip: 'My QR code',
                              backgroundColor: const Color(0xFF14679E),
                              foregroundColor: Colors.white,
                              onPressed: widget.onRequireSignIn,
                              child: const Icon(
                                Icons.qr_code_scanner,
                                size: 23,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Initialization failures still leave the read-only product available.
class GuestUnavailableApp extends StatelessWidget {
  const GuestUnavailableApp({super.key, required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Paul',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'NotoSans',
      scaffoldBackgroundColor: const Color(0xFFF4F4F4),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF14679E)),
    ),
    home: Builder(
      builder: (context) => GuestPreview(
        onRequireSignIn: () => showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Connection unavailable'),
            content: const Text(
              'Could not connect to Paul. You can keep exploring the preview or retry to sign in.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Back to preview'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  onRetry();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
