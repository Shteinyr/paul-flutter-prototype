import 'dart:async';
import 'package:flutter/material.dart';

import '../app.dart';
import '../community/community_controller.dart';
import '../community/community_api.dart';
import '../community/community_views.dart';
import '../profile/public_profile_view.dart';
import '../search/skill_search_controller.dart';
import '../search/skill_search_view.dart';
import 'public_preview_api.dart';
import 'guest_invitation_prompt.dart';
import 'public_avatar_image.dart';
import 'chat_controller.dart';
import 'chat_api.dart';

class _PublicDraftStore implements ChatStateStore {
  @override
  Future<String?> read(String userId) async => null;
  @override
  Future<void> write(String userId, String state) async {}
}

class PublicGuestBrowsingState {
  int tab = 0, epoch = 0;
  String? profileId, requestId;
  bool restoreOrigin = false, leavingForEntry = false;
  void reset() {
    tab = 0;
    epoch++;
    profileId = null;
    requestId = null;
    restoreOrigin = false;
    leavingForEntry = false;
  }
}

class PublicGuestPreview extends StatefulWidget {
  const PublicGuestPreview({
    super.key,
    required this.repository,
    required this.onRequireSignIn,
    required this.onEditProfile,
    this.browsingState,
    this.limited = false,
  });
  final PublicPreviewRepository repository;
  final VoidCallback onRequireSignIn;
  final VoidCallback onEditProfile;
  final PublicGuestBrowsingState? browsingState;
  final bool limited;
  @override
  State<PublicGuestPreview> createState() => _PublicGuestPreviewState();
}

class _PublicGuestPreviewState extends State<PublicGuestPreview> {
  late final _browse = widget.browsingState ?? PublicGuestBrowsingState();
  late final _repository = PublicSearchRepository(widget.repository);
  late final _search = SkillSearchController(_repository);
  late final _community = CommunityController(
    PublicCommunityRepository(
      widget.repository,
      onOpenRequest: (id) => _browse.requestId = id,
    ),
    drafts: _PublicDraftStore(),
  );
  List<PublicProfile> _profiles = const [];
  Map<String, dynamic>? _cursor;
  bool _loading = true, _loadingMore = false;
  String? _error;
  int _tab = 0, _generation = 0;
  bool _openedHiring = false;
  @override
  void initState() {
    super.initState();
    final epoch = ++_browse.epoch;
    _tab = _browse.tab;
    _openedHiring = _tab == 1;
    _browse.leavingForEntry = false;
    final restore = _browse.restoreOrigin;
    _browse.restoreOrigin = false;
    _load();
    if (restore) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _browse.epoch != epoch) return;
        if (_browse.profileId != null) {
          _open(_browse.profileId!);
        } else if (_browse.requestId != null) {
          _restoreRequest(_browse.requestId!);
        }
      });
    }
  }

  void _requireSignIn() {
    _browse.tab = _tab;
    if (widget.limited) {
      widget.onRequireSignIn();
      return;
    }
    _browse.restoreOrigin = true;
    _browse.leavingForEntry = true;
    widget.onRequireSignIn();
  }

  void _restoreRequest(String id) {
    final epoch = _browse.epoch;
    unawaited(
      Navigator.of(context)
          .push<void>(
            MaterialPageRoute(
              builder: (_) => CommunityDetailView(
                controller: _community,
                requestId: id,
                onMessage: (_, _) async => _requireSignIn(),
                avatarFor: (peer) => _avatar(peer.id, 65),
              ),
            ),
          )
          .whenComplete(() {
            if (_browse.epoch == epoch && !_browse.leavingForEntry) {
              _browse.requestId = null;
            }
          }),
    );
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
    repository: widget.repository,
    size: size,
  );
  void _open(String id) {
    final epoch = _browse.epoch;
    _browse.profileId = id;
    _browse.requestId = null;
    unawaited(
      Navigator.of(context)
          .push<void>(
            MaterialPageRoute(
              builder: (_) => _PublicProfilePage(
                repository: widget.repository,
                id: id,
                onMessage: _requireSignIn,
                limited: widget.limited,
              ),
            ),
          )
          .whenComplete(() {
            if (_browse.epoch == epoch && !_browse.leavingForEntry) {
              _browse.profileId = null;
            }
          }),
    );
  }

  Widget _contacts() => Stack(
    children: [
      SkillSearchView(
        controller: _search,
        avatarFor: (hit) => _avatar(hit.id, 65),
        onOpen: (hit) async => _open(hit.id),
        onAskCommunity: (_) => _requireSignIn(),
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
                  avatar: PublicProfileAvatar(
                    profile: p,
                    repository: widget.repository,
                    size: 65,
                  ),
                  onOpen: () => _open(p.id),
                ),
              if (_cursor != null)
                TextButton(
                  onPressed: _loadingMore ? null : () => _load(more: true),
                  child: Text(
                    _loadingMore
                        ? 'Loading…'
                        : widget.limited
                        ? 'more Contacts'
                        : 'Load more',
                  ),
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
          onPressed: _requireSignIn,
          child: const Icon(Icons.qr_code_scanner, size: 23),
        ),
      ),
    ],
  );

  Widget _hiring() => widget.limited
      ? _PublicHiringFeed(
          controller: _community,
          active: _tab == 1,
          avatarFor: (peer) => _avatar(peer.id, 65),
          onOpen: (request) => _restoreRequest(request.id),
        )
      : CommunityFeedView(
          controller: _community,
          embedded: true,
          onInvite: _requireSignIn,
          onMessage: (_, _) async => _requireSignIn(),
          avatarFor: (peer) => _avatar(peer.id, 65),
        );

  Widget _chat() => Center(child: GuestChatPrompt(onSignUp: _requireSignIn));

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
                        _browse.tab = tab;
                        _browse.profileId = null;
                        _browse.requestId = null;
                        setState(() {
                          _tab = tab;
                          if (tab == 1) _openedHiring = true;
                        });
                      }
                    },
                  ),
                ),
                Expanded(
                  child: widget.limited
                      ? IndexedStack(
                          index: _tab,
                          children: [
                            _contacts(),
                            if (_openedHiring || _tab == 1)
                              _hiring()
                            else
                              const SizedBox.shrink(),
                            _chat(),
                          ],
                        )
                      : switch (_tab) {
                          1 => _hiring(),
                          2 => _chat(),
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

/// P16 61988:1772/1796/1797/1799/1864. The public feed shares the data
/// controller and source row, but never adds the member compose controls.
class _PublicHiringFeed extends StatefulWidget {
  const _PublicHiringFeed({
    required this.controller,
    required this.avatarFor,
    required this.onOpen,
    this.active = true,
  });
  final CommunityController controller;
  final Widget Function(ChatPeer) avatarFor;
  final ValueChanged<CommunityRequest> onOpen;
  final bool active;
  @override
  State<_PublicHiringFeed> createState() => _PublicHiringFeedState();
}

class _PublicHiringFeedState extends State<_PublicHiringFeed>
    with WidgetsBindingObserver {
  final _scroll = ScrollController();
  Timer? _refresh;
  bool _resumed = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(widget.controller.refresh());
    _refresh = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_resumed &&
          widget.active &&
          ModalRoute.of(context)?.isCurrent == true) {
        unawaited(widget.controller.refresh());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (_resumed && widget.active) unawaited(widget.controller.refresh());
  }

  String? _group(CommunityRequest request) {
    final age = widget.controller.serverNow.difference(request.createdAt);
    if (age < const Duration(days: 1)) return 'Today';
    if (age < const Duration(days: 7)) return 'Last week';
    return null;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final requests = controller.requests
          .where((item) => item.expiresAt.isAfter(controller.serverNow))
          .toList();
      return RefreshIndicator(
        onRefresh: controller.refresh,
        child: ListView(
          key: const Key('community-feed'),
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(34, 70, 34, 40),
          children: [
            if (controller.loading && requests.isEmpty)
              const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            if (controller.error != null) ...[
              Text(controller.error!),
              TextButton(
                onPressed: controller.refresh,
                child: const Text('Retry'),
              ),
            ],
            if (!controller.loading &&
                controller.error == null &&
                requests.isEmpty)
              const Text('No active requests yet', textAlign: TextAlign.center),
            for (var index = 0; index < requests.length; index++) ...[
              if (index == 0 ||
                  _group(requests[index]) != _group(requests[index - 1])) ...[
                if (index > 0) const SizedBox(height: 56),
                if (_group(requests[index]) case final String group) ...[
                  Text(
                    group,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 20 / 12,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                  const SizedBox(height: 33),
                ],
              ],
              Padding(
                padding: const EdgeInsets.only(bottom: 13),
                child: Column(
                  children: [
                    Semantics(
                      button: true,
                      child: InkWell(
                        key: ValueKey('community-${requests[index].id}'),
                        onTap: () => widget.onOpen(requests[index]),
                        child: SizedBox(
                          height: 82,
                          child: HiringRequestRow(
                            name: requests[index].author.name,
                            skill: requests[index].skill,
                            avatar: widget.avatarFor(requests[index].author),
                          ),
                        ),
                      ),
                    ),
                    const Divider(height: 1, color: Color(0xFFCDDEE8)),
                  ],
                ),
              ),
            ],
            if (controller.pageError != null) Text(controller.pageError!),
            if (controller.hasMore)
              TextButton(
                key: const Key('public-more-hiring'),
                onPressed: controller.loadingMore ? null : controller.loadMore,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF14679E),
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w300,
                  ),
                ),
                child: Text(
                  controller.loadingMore ? 'Loading…' : 'More hiring',
                ),
              ),
          ],
        ),
      );
    },
  );

  @override
  void dispose() {
    _refresh?.cancel();
    _scroll.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class PublicProfileAvatar extends StatefulWidget {
  const PublicProfileAvatar({
    super.key,
    required this.profile,
    required this.repository,
    required this.size,
  });
  final PublicProfile? profile;
  final PublicPreviewRepository repository;
  final double size;
  @override
  State<PublicProfileAvatar> createState() => _PublicProfileAvatarState();
}

class _PublicProfileAvatarState extends State<PublicProfileAvatar> {
  late PublicProfile? _profile = widget.profile;
  int _generation = 0, _attempt = 0;
  bool _recoveryUsed = false, _refreshing = false;

  @override
  void didUpdateWidget(PublicProfileAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile?.id != widget.profile?.id ||
        oldWidget.profile?.avatarUrl != widget.profile?.avatarUrl ||
        oldWidget.repository != widget.repository) {
      _generation++;
      _profile = widget.profile;
      _attempt = 0;
      _recoveryUsed = false;
      _refreshing = false;
    }
  }

  // A lower, lazily built row may first fetch its signed URL after expiry.
  // Renew this card once, without reloading the list or its browsing state.
  void _recover() {
    final profile = _profile;
    if (_recoveryUsed || profile?.avatarUrl == null) return;
    _recoveryUsed = true;
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      setState(() => _refreshing = true);
      unawaited(_refreshProfile(profile!, generation));
    });
  }

  Future<void> _refreshProfile(PublicProfile previous, int generation) async {
    bool current() => mounted && generation == _generation;
    try {
      final next = await widget.repository.profile(previous.id);
      if (!current()) return;
      // The server may remove a portrait/profile while it is being renewed.
      // Never replace one person's portrait with a different card's response.
      final profile = next?.id == previous.id ? next : null;
      if (profile?.avatarUrl != null &&
          profile!.avatarUrl == previous.avatarUrl) {
        // A transient failure can return the same signature. Evict the failed
        // image key and retry once even when the transport URL is unchanged.
        await publicAvatarImage(profile.avatarUrl!).evict();
        if (!current()) return;
      }
      setState(() {
        _profile = profile;
        _attempt++;
        _refreshing = false;
      });
    } catch (_) {
      if (current()) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = _profile?.avatarUrl;
    if (url == null) return ProfileAvatar(size: widget.size);
    return ClipOval(
      child: Image(
        key: ValueKey((_profile!.id, url, _attempt)),
        image: publicAvatarImage(url),
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
            frame != null || wasSynchronouslyLoaded
            ? child
            : ProfileAvatar(size: widget.size, loading: true),
        errorBuilder: (_, _, _) {
          _recover();
          return ProfileAvatar(size: widget.size, loading: _refreshing);
        },
      ),
    );
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }
}

class _PublicProfilePage extends StatefulWidget {
  const _PublicProfilePage({
    required this.repository,
    required this.id,
    required this.onMessage,
    this.limited = false,
  });
  final PublicPreviewRepository repository;
  final String id;
  final VoidCallback onMessage;
  final bool limited;
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
        // P16 source 61724:6822; native profile typography is unchanged.
        nameStyle: widget.limited
            ? const TextStyle(
                fontSize: 16,
                height: 20 / 16,
                fontWeight: FontWeight.w500,
              )
            : null,
        avatar: PublicProfileAvatar(
          profile: p,
          repository: widget.repository,
          size: 144,
        ),
        contactCount: p.contactCount,
        onChat: widget.onMessage,
      );
    },
  );
}
