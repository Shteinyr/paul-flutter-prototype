import 'package:flutter/material.dart';

import '../app.dart';
import '../community/community_controller.dart';
import '../community/community_views.dart';
import '../profile/public_profile_view.dart';
import '../search/skill_search_controller.dart';
import '../search/skill_search_view.dart';
import 'public_preview_api.dart';
import 'chat_controller.dart';

class _PublicDraftStore implements ChatStateStore {
  @override
  Future<String?> read(String userId) async => null;
  @override
  Future<void> write(String userId, String state) async {}
}

class PublicGuestPreview extends StatefulWidget {
  const PublicGuestPreview({
    super.key,
    required this.repository,
    required this.onRequireSignIn,
    required this.onEditProfile,
  });
  final PublicPreviewRepository repository;
  final VoidCallback onRequireSignIn;
  final VoidCallback onEditProfile;
  @override
  State<PublicGuestPreview> createState() => _PublicGuestPreviewState();
}

class _PublicGuestPreviewState extends State<PublicGuestPreview> {
  late final _repository = PublicSearchRepository(widget.repository);
  late final _search = SkillSearchController(_repository);
  late final _community = CommunityController(
    PublicCommunityRepository(widget.repository),
    drafts: _PublicDraftStore(),
  );
  List<PublicProfile> _profiles = const [];
  Map<String, dynamic>? _cursor;
  bool _loading = true, _loadingMore = false;
  String? _error;
  int _tab = 0, _generation = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (more && (_loadingMore || _cursor == null)) return;
    final generation = ++_generation;
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
      }
      _error = null;
    });
    try {
      final page = await widget.repository.profiles(
        cursor: more ? _cursor : null,
      );
      if (!mounted || generation != _generation) return;
      _repository.remember(page.profiles);
      setState(() {
        _profiles = more ? [..._profiles, ...page.profiles] : page.profiles;
        _cursor = page.nextCursor;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = 'Could not load profiles. Please retry.');
      }
    }
    if (mounted && generation == _generation) {
      setState(() {
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Widget _avatar(String id, double size) => PublicProfileAvatar(
    profile: widget.repository.cachedProfile(id) ?? _repository.saved[id],
    size: size,
  );
  void _open(String id) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => _PublicProfilePage(
        repository: widget.repository,
        id: id,
        onMessage: widget.onRequireSignIn,
      ),
    ),
  );
  Widget _contacts() => Stack(
    children: [
      SkillSearchView(
        controller: _search,
        avatarFor: (hit) => _avatar(hit.id, 65),
        onOpen: (hit) async => _open(hit.id),
        onAskCommunity: (_) => widget.onRequireSignIn(),
        contacts: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            key: const Key('public-guest-contacts'),
            padding: const EdgeInsets.fromLTRB(37.5, 24, 37.5, 88),
            children: [
              if (_loading && _profiles.isEmpty)
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
              if (_error != null) ...[
                Text(_error!),
                TextButton(
                  onPressed: () => _load(),
                  child: const Text('Retry'),
                ),
              ],
              if (!_loading && _error == null && _profiles.isEmpty)
                const Text('No profiles found'),
              for (final p in _profiles)
                ContactRow(
                  name: p.profile.name,
                  occupation: p.profile.occupation,
                  avatar: PublicProfileAvatar(profile: p, size: 65),
                  onOpen: () => _open(p.id),
                ),
              if (_cursor != null)
                TextButton(
                  onPressed: _loadingMore ? null : () => _load(more: true),
                  child: Text(_loadingMore ? 'Loading…' : 'Load more'),
                ),
            ],
          ),
        ),
      ),
      Positioned(
        right: 28,
        bottom: 24,
        child: FloatingActionButton.small(
          tooltip: 'My QR code',
          backgroundColor: const Color(0xFF14679E),
          foregroundColor: Colors.white,
          onPressed: widget.onRequireSignIn,
          child: const Icon(Icons.qr_code_scanner, size: 23),
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
            padding: const EdgeInsets.only(top: 70),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: ProfileNavigation(
                    selected: _tab,
                    onSelected: (tab) {
                      if (tab == 3) {
                        widget.onEditProfile();
                      } else {
                        setState(() => _tab = tab);
                      }
                    },
                  ),
                ),
                Expanded(
                  child: switch (_tab) {
                    1 => CommunityFeedView(
                      controller: _community,
                      embedded: true,
                      onInvite: widget.onRequireSignIn,
                      onMessage: (_, _) async => widget.onRequireSignIn(),
                      avatarFor: (peer) => _avatar(peer.id, 65),
                    ),
                    2 => Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Sign in to view your messages.'),
                          TextButton(
                            onPressed: widget.onRequireSignIn,
                            child: const Text('Sign in'),
                          ),
                        ],
                      ),
                    ),
                    _ => _contacts(),
                  },
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
    _generation++;
    _search.dispose();
    _community.dispose();
    super.dispose();
  }
}

class PublicProfileAvatar extends StatelessWidget {
  const PublicProfileAvatar({
    super.key,
    required this.profile,
    required this.size,
  });
  final PublicProfile? profile;
  final double size;
  @override
  Widget build(BuildContext context) {
    final url = profile?.avatarUrl;
    if (url == null) return ProfileAvatar(size: size);
    return ClipOval(
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => ProfileAvatar(size: size),
      ),
    );
  }
}

class _PublicProfilePage extends StatefulWidget {
  const _PublicProfilePage({
    required this.repository,
    required this.id,
    required this.onMessage,
  });
  final PublicPreviewRepository repository;
  final String id;
  final VoidCallback onMessage;
  @override
  State<_PublicProfilePage> createState() => _PublicProfilePageState();
}

class _PublicProfilePageState extends State<_PublicProfilePage> {
  late Future<PublicProfile?> _profile = widget.repository.profile(widget.id);
  @override
  Widget build(BuildContext context) => FutureBuilder<PublicProfile?>(
    future: _profile,
    initialData: widget.repository.cachedProfile(widget.id),
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return ProfilePage(
          title: 'Public Profile',
          child: Center(
            child: TextButton(
              onPressed: () => setState(
                () => _profile = widget.repository.profile(widget.id),
              ),
              child: const Text('Could not load profile. Retry'),
            ),
          ),
        );
      }
      final p = snapshot.data;
      if (p == null) {
        return ProfilePage(
          title: 'Public Profile',
          child: Center(
            child: snapshot.connectionState == ConnectionState.done
                ? const Text('This profile is unavailable.')
                : const CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      }
      return PublicProfileView(
        profile: p.profile,
        avatar: PublicProfileAvatar(profile: p, size: 144),
        contactCount: p.contactCount,
        onChat: widget.onMessage,
      );
    },
  );
}
