import 'package:flutter/material.dart';

import '../app.dart';
import '../chat/demo_chat_controller.dart';
import '../chat/demo_chat_view.dart';
import '../demo_contacts.dart';
import '../community/community_views.dart';
import '../onboarding/onboarding_flow.dart';
import '../profile/demo_profile.dart';
import '../profile/public_profile_view.dart';
import '../profile/user_profile.dart';
import '../search/skill_search_controller.dart';
import '../search/skill_search_view.dart';
import 'guest_search_repository.dart';

/// Sample data is independent of membership, demo history and onboarding storage.
class GuestPreview extends StatefulWidget {
  const GuestPreview({
    super.key,
    required this.onRequireSignIn,
    required this.onEditProfile,
  });
  final VoidCallback onRequireSignIn;
  final VoidCallback onEditProfile;

  @override
  State<GuestPreview> createState() => _GuestPreviewState();
}

class _GuestPreviewState extends State<GuestPreview> {
  static const _paulId = 'preview-paul';
  late Future<UserProfile> _paul = loadDemoProfile();
  DemoChatController? _chat;
  SkillSearchController? _search;
  final _people = <String, DemoContact>{demoChatContact.id: demoChatContact};
  UserProfile? _paulProfile;
  int _tab = 0;

  void _initialize(UserProfile paul) {
    if (_chat != null) return;
    _paulProfile = paul;
    final contact = DemoContact(
      id: _paulId,
      name: paul.name,
      occupation: paul.occupation,
      summary: paul.summary,
      skills: paul.skills,
      searchingSkills: paul.searchingSkills,
    );
    _people[_paulId] = contact;
    // No preferences store: never loads PaulDemoApp history or account drafts.
    _chat = DemoChatController(additionalContacts: [contact]);
    _search = SkillSearchController(
      GuestSearchRepository({
        for (final entry in _people.entries) entry.key: entry.value.profile,
      }),
    );
  }

  Widget _avatar(String id, double size) => id == _paulId
      ? ProfileAvatar(photo: _paulProfile!.photo, size: size)
      : ProfileAvatar(asset: _people[id]!.photoAsset, size: size);

  void _open(String id) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Banner(
        message: 'Preview',
        location: BannerLocation.topEnd,
        color: const Color(0xFF14679E),
        child: PublicProfileView(
          profile: id == _paulId ? _paulProfile! : _people[id]!.profile,
          avatar: _avatar(id, 144),
          onChat: () => _openChat(id),
        ),
      ),
    ),
  );

  void _openChat(String id) {
    _chat!.open(id);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Banner(
          message: 'Preview',
          location: BannerLocation.topEnd,
          color: const Color(0xFF14679E),
          child: DemoChatView(
            contact: _people[id]!,
            controller: _chat!,
            ownAvatar: const ProfileAvatar(size: 48),
            peerAvatar: _avatar(id, 48),
            onSendAttempt: widget.onRequireSignIn,
          ),
        ),
      ),
    );
  }

  Widget _contacts() => Stack(
    children: [
      SkillSearchView(
        controller: _search!,
        avatarFor: (hit) => _avatar(hit.id, 65),
        onOpen: (hit) async => _open(hit.id),
        contacts: ListView(
          key: const Key('guest-contacts'),
          padding: const EdgeInsets.fromLTRB(37.5, 24, 37.5, 88),
          children: [
            for (final id in [_paulId, demoChatContact.id])
              ContactRow(
                name: _people[id]!.name,
                occupation: _people[id]!.occupation,
                avatar: _avatar(id, 65),
                onOpen: () => _open(id),
              ),
          ],
        ),
      ),
      Positioned(
        right: 28,
        bottom: 24,
        child: ListenableBuilder(
          listenable: _search!,
          builder: (context, _) => _search!.idle
              ? FloatingActionButton.small(
                  tooltip: 'My QR code',
                  backgroundColor: const Color(0xFF14679E),
                  foregroundColor: Colors.white,
                  onPressed: widget.onRequireSignIn,
                  child: const Icon(Icons.qr_code_scanner, size: 23),
                )
              : const SizedBox.shrink(),
        ),
      ),
    ],
  );

  Widget _chats() => ListenableBuilder(
    listenable: _chat!,
    builder: (context, _) => ListView(
      key: const Key('guest-chat-list'),
      padding: const EdgeInsets.fromLTRB(37.5, 24, 37.5, 88),
      children: [
        for (final thread in _chat!.conversations)
          ContactRow(
            key: Key('guest-thread-${thread.contactId}'),
            name: _people[thread.contactId]!.name,
            occupation: _people[thread.contactId]!.occupation,
            avatar: _avatar(thread.contactId, 65),
            unread: thread.unread,
            onOpen: () => _openChat(thread.contactId),
          ),
      ],
    ),
  );

  Widget _hiring() => ListView(
    key: const Key('guest-hiring'),
    padding: const EdgeInsets.fromLTRB(37.5, 47, 37.5, 40),
    children: [
      const Text('Today', style: TextStyle(fontSize: 20)),
      const SizedBox(height: 30),
      InkWell(
        onTap: () => _open(_paulId),
        child: HiringRequestRow(
          name: _people[_paulId]!.name,
          skill: 'Sales Representative',
          avatar: _avatar(_paulId, 65),
        ),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Divider(color: Color(0xFFCDDEE8)),
      ),
      InkWell(
        onTap: () => _open(demoChatContact.id),
        child: HiringRequestRow(
          name: demoChatContact.name,
          skill: 'Photographer',
          avatar: _avatar(demoChatContact.id, 65),
        ),
      ),
      const SizedBox(height: 56),
      const Text('Last Week', style: TextStyle(fontSize: 20)),
      const SizedBox(height: 30),
      InkWell(
        onTap: () => _open(_paulId),
        child: HiringRequestRow(
          name: _people[_paulId]!.name,
          skill: 'SMM Marketing',
          avatar: _avatar(_paulId, 65),
        ),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Divider(color: Color(0xFFCDDEE8)),
      ),
      InkWell(
        onTap: () => _open(demoChatContact.id),
        child: HiringRequestRow(
          name: demoChatContact.name,
          skill: 'Babysitter',
          avatar: _avatar(demoChatContact.id, 65),
        ),
      ),
    ],
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
                    selected: _tab,
                    onSelected: (index) {
                      if (index == 3) {
                        widget.onEditProfile();
                      } else {
                        setState(() => _tab = index);
                      }
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
                      _initialize(paul);
                      return switch (_tab) {
                        1 => _hiring(),
                        2 => _chats(),
                        _ => _contacts(),
                      };
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

  @override
  void dispose() {
    _search?.dispose();
    _chat?.dispose();
    super.dispose();
  }
}

/// Initialization failures still leave the read-only product available.
class GuestUnavailableApp extends StatelessWidget {
  const GuestUnavailableApp({
    super.key,
    required this.onRetry,
    this.message =
        'Could not connect to Paul. You can keep exploring the preview or retry to sign in.',
  });
  final VoidCallback onRetry;
  final String message;

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
        onEditProfile: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (draftContext) => OnboardingFlow(
              onBack: () => Navigator.of(draftContext).pop(),
              onContinueToRegistration: (_) => showDialog<void>(
                context: draftContext,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Connection unavailable'),
                  content: Text(message),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('Back to profile'),
                    ),
                    TextButton(onPressed: onRetry, child: const Text('Retry')),
                  ],
                ),
              ),
            ),
          ),
        ),
        onRequireSignIn: () => showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Connection unavailable'),
            content: Text(message),
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
