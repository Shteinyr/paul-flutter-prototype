import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart';
import '../config/app_configuration.dart';
import '../platform/storage/platform_storage.dart';
import '../platform/links/platform_links.dart';
import '../platform/photos/platform_photos.dart';
import '../admin/admin_api.dart';
import '../admin/admin_view.dart';
import '../admin/managed_profile_header.dart';
import '../admin/operator_inbox_view.dart';
import '../community/community_api.dart';
import '../community/community_controller.dart';
import '../community/community_views.dart';
import '../account/deletion.dart';
import '../account/deletion_view.dart';
import '../push/push_browser.dart';
import '../push/push_api.dart';
import '../push/push_controller.dart';
import '../onboarding/onboarding_draft_store.dart';
import '../onboarding/onboarding_flow.dart';
import '../onboarding/mobile_auth_actions.dart';
import 'invitation_entry_view.dart';
import '../profile/profile_controller.dart';
import '../profile/profile_conflict_dialog.dart';
import '../profile/public_profile_view.dart';
import '../profile/user_profile.dart';
import '../search/skill_search_api.dart';
import '../search/skill_search_controller.dart';
import '../search/skill_search_view.dart';
import 'browser_storage.dart';
import 'auth_callback.dart';
import 'live_api.dart';
import 'member_capabilities.dart';
import 'continue_setup_dialog.dart';
import 'live_qr_view.dart';
import 'guest_preview.dart';
import 'public_preview_api.dart';
import 'public_guest_preview.dart';
import 'chat_api.dart';
import 'chat_controller.dart';
import 'live_chat_list.dart';
import 'live_chat_view.dart';
import 'live_disconnect_dialog.dart';

const _blue = Color(0xFF14679E);
const _inviteKey = 'paul.live.pending.invitation.v1';
const _draftKey = 'paul.live.pending.profile.v1';
const _finalizeKey = 'paul.live.pending.finalize.v1';
const _entryReturnKey = 'paul.live.entry.return.v1';
const _pendingOwnerKey = 'paul.live.pending.owner.v1';
const _pendingSessionKey = 'paul.live.pending.session.v1';
// A dismissed failed redirect must not consume a saved invite after reload.
const _failedCallbackKey = 'paul.live.pending.auth-failure.v1';

class PaulLiveApp extends StatefulWidget {
  const PaulLiveApp({
    super.key,
    required this.client,
    required this.appUrl,
    this.purpose = AppPurpose.review,
    this.googleEnabled = false,
    this.appleEnabled = false,
    this.loadAuthProviders,
    this.authCallback = false,
    this.authCallbackFailed = false,
    this.draftPreferences,
    this.chatRepositoryFor,
    this.searchRepositoryFor,
    this.communityRepositoryFor,
    this.deletionStore,
    this.deletionRepository,
    this.recoverSignIn,
    this.pushBrowser,
    this.pushRepositoryFor,
    this.publicPreviewRepository,
  });
  final SupabaseClient client;
  final Uri appUrl;
  final AppPurpose purpose;
  final bool googleEnabled;
  final bool appleEnabled;
  final Future<({bool google, bool apple})> Function()? loadAuthProviders;
  final bool authCallback;
  final bool authCallbackFailed;
  final SharedPreferencesAsync? draftPreferences;
  final ChatRepository Function(String userId)? chatRepositoryFor;
  final SkillSearchRepository Function(String userId)? searchRepositoryFor;
  final CommunityRepository Function(String userId)? communityRepositoryFor;
  final DeletionStore? deletionStore;
  final DeletionRepository? deletionRepository;
  final Future<void> Function()? recoverSignIn;
  final PushBrowser? pushBrowser;
  final PublicPreviewRepository? publicPreviewRepository;
  final PushRepository Function(String userId, String sessionId)?
  pushRepositoryFor;
  @override
  State<PaulLiveApp> createState() => _PaulLiveAppState();
}

class _PaulLiveAppState extends State<PaulLiveApp> with WidgetsBindingObserver {
  late final LiveApi _api;
  late final DeletionController _deletions;
  late final StreamSubscription<AuthState> _auth;
  final _navigator = GlobalKey<NavigatorState>();
  final _publicBrowsing = PublicGuestBrowsingState();
  ProfileController? _profile;
  MemberCapabilities? _capabilities;
  int _capabilityGeneration = 0;
  final _networkUpdates = ValueNotifier(const MemberNetwork());
  MemberNetwork get _network => _networkUpdates.value;
  set _network(MemberNetwork value) {
    _networkUpdates.value = value;
    if (value.own != null) _publicBrowsing.reset();
  }

  LiveChatController? _chat;
  SkillSearchController? _search;
  CommunityController? _community;
  late final PushBrowser _pushBrowser;
  late final StreamSubscription<PushClick> _pushClicks;
  PushController? _push;
  PushClick? _pendingPushClick;
  BuildContext? _homeContext;
  bool _openingPush = false;
  bool _signingOut = false;
  Future<bool>? _networkRefresh;
  Future<void>? _loadingTask;
  ({String? user, String? session})? _loadingScope;
  bool _openingChat = false;
  bool _resumed = true;
  final _peerPhotos = <String, ({String? path, Future<Uint8List?> photo})>{};
  UserProfile? _draft;
  String? _credential;
  String? _identity;
  String? _authSession;
  String? _error;
  bool _invalidCredential = false;
  bool _loading = true;
  bool _acceptedInvite = false;
  bool _entering = false;
  bool _callbackFailure = false;
  bool _deferInvitation = false;
  String? get _visibleError =>
      _callbackFailure ? authCallbackFailureMessage : _error;
  bool _editingGuestDraft = false;
  bool _choosingProvider = false;
  int _entryGeneration = 0;
  bool _checking = false;
  int _loadGeneration = 0;
  int _tab = 0;

  Future<void> Function()? _stopPlatformLinks;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _api = LiveApi(widget.client);
    _deletions = DeletionController(
      widget.deletionRepository ?? SupabaseDeletionApi(widget.client),
      widget.deletionStore ?? PreferenceDeletionStore(),
    );
    _deletions.addListener(_purgeDeletedLocalData);
    unawaited(_deletions.load());
    final fragment = Uri.base.fragment;
    _credential = fragment.startsWith('invite=')
        ? fragment.substring(7)
        : readSessionValue(_inviteKey);
    if (_credential != null) writeSessionValue(_inviteKey, _credential!);
    _deferInvitation = readSessionValue(_failedCallbackKey) == '1';
    if (fragment.startsWith('invite=') ||
        (widget.authCallback && !widget.authCallbackFailed)) {
      _resumeInvitation();
    }
    clearInviteFromAddress();
    final draft = readSessionValue(_draftKey);
    if (draft != null) {
      try {
        _draft = UserProfile.decode(draft);
      } catch (_) {
        removeSessionValue(_draftKey);
      }
    }
    if (widget.purpose == AppPurpose.app) _entering = true;
    _identity = widget.client.auth.currentUser?.id;
    _authSession = pushSessionId(widget.client);
    _pushBrowser = widget.pushBrowser ?? createPushBrowser();
    final click = _pushBrowser.takeClick();
    if (click?.recipientId == _identity) _pendingPushClick = click;
    if (_identity == null) unawaited(_setPushIdentity(null));
    _pushClicks = _pushBrowser.clicks.listen((click) {
      if (click.recipientId != widget.client.auth.currentUser?.id) return;
      _pendingPushClick = click;
      unawaited(_drainPushClick());
    });
    final entryReturn = readSessionValue(_entryReturnKey);
    _editingGuestDraft = entryReturn == 'editing' && !widget.authCallback;
    _entering =
        entryReturn == 'draft' ||
        (widget.authCallback && readSessionValue(_finalizeKey) == '1');
    if (!widget.authCallback) removeSessionValue(_finalizeKey);
    if (widget.authCallbackFailed) _recordCallbackFailure();
    _auth = widget.client.auth.onAuthStateChange.listen(
      (event) {
        if (event.event == AuthChangeEvent.tokenRefreshed) return;
        final userId = event.session?.user.id;
        for (final record in _deletions.records.where(
          (item) =>
              item.self &&
              item.actorId == userId &&
              !_deletions.confirmed(item),
        )) {
          unawaited(_deletions.retry(record));
        }
        unawaited(_load());
      },
      onError: (Object _) {
        if (mounted) {
          setState(() {
            _loading = false;
            _recordCallbackFailure();
          });
        }
      },
    );
    unawaited(_load());
    _stopPlatformLinks = observePlatformInvitations(widget.appUrl, (
      credential,
    ) {
      if (!mounted) return;
      _entryGeneration++;
      writeSessionValue(_inviteKey, credential);
      _resumeInvitation();
      setState(() {
        _credential = credential;
        _acceptedInvite = false;
        _entering = true;
        _error = null;
      });
      if (_network.own != null) unawaited(_load());
    });
  }

  final _purgedAccounts = <String>{};
  void _purgeDeletedLocalData() {
    for (final record in _deletions.records) {
      if (!record.self ||
          !_deletions.confirmed(record) ||
          _purgedAccounts.contains(record.actorId)) {
        continue;
      }
      try {
        deleteAccountStorage(record.actorId);
        _purgedAccounts.add(record.actorId);
      } catch (_) {
        // Retry on the next recovery update; keep the deletion receipt itself.
      }
    }
  }

  void _resumeInvitation() {
    _deferInvitation = false;
    removeSessionValue(_failedCallbackKey);
  }

  void _recordCallbackFailure() {
    _callbackFailure = true;
    _deferInvitation = true;
    writeSessionValue(_failedCallbackKey, '1');
    removeSessionValue(_finalizeKey);
    if (_draft?.hasData == true && readSessionValue(_entryReturnKey) == null) {
      writeSessionValue(_entryReturnKey, 'draft');
    }
    _entering = true;
    _editingGuestDraft = false;
    _acceptedInvite = false;
  }

  Future<void> _clearPending() async {
    removeSessionValue(_inviteKey);
    removeSessionValue(_draftKey);
    removeSessionValue(_finalizeKey);
    removeSessionValue(_entryReturnKey);
    removeSessionValue(_pendingOwnerKey);
    removeSessionValue(_pendingSessionKey);
    removeSessionValue('paul.live.sign-in-existing.v1');
    _resumeInvitation();
    _callbackFailure = false;
    _credential = null;
    clearOnboardingPhotoOwner();
    _draft = null;
    _acceptedInvite = false;
    _invalidCredential = false;
  }

  Future<void> _load() {
    final scope = (
      user: widget.client.auth.currentUser?.id,
      session: pushSessionId(widget.client),
    );
    final running = _loadingTask;
    // Without a session marker, a new sign-in cannot safely share an older load.
    final knownScope = scope.user == null || scope.session != null;
    if (knownScope && running != null && _loadingScope == scope) return running;
    final operation = _loadMember();
    _loadingScope = scope;
    _loadingTask = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_loadingTask, operation)) _loadingTask = null;
      }),
    );
    return operation;
  }

  Future<void> _loadMember() async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    final identity = widget.client.auth.currentUser?.id;
    final session = pushSessionId(widget.client);
    final profileSession =
        session ?? widget.client.auth.currentSession?.accessToken;
    setState(() {
      _loading = true;
      _error = null;
    });
    if (_identity != identity || _authSession != session) {
      _pendingPushClick = null;
      _push?.dispose();
      _push = null;
      unawaited(_setPushIdentity(identity));
      _navigator.currentState?.popUntil((route) => route.isFirst);
      _disposeChat();
      _disposeSearch();
      _networkRefresh = null;
      _peerPhotos.clear();
      _openingChat = false;
      _profile?.dispose();
      _profile = null;
      _capabilities = null;
      _capabilityGeneration++;
      _network = const MemberNetwork();
      _tab = 0;
      if (_identity != null && _identity != identity) {
        await _clearPending();
        await OnboardingDraftStore(
          preferences: widget.draftPreferences,
        ).clear();
      }
      if (!mounted ||
          generation != _loadGeneration ||
          widget.client.auth.currentUser?.id != identity) {
        return;
      }
      _identity = identity;
      _authSession = session;
    }
    if (!mounted ||
        generation != _loadGeneration ||
        widget.client.auth.currentUser?.id != identity) {
      return;
    }
    try {
      if (identity != null && readSessionValue(_finalizeKey) == '1') {
        final owner = readSessionValue(_pendingOwnerKey);
        final previousSession = readSessionValue(_pendingSessionKey);
        if ((owner != null && owner != identity) ||
            (previousSession != null && previousSession != session)) {
          await _clearPending();
          await OnboardingDraftStore(
            preferences: widget.draftPreferences,
          ).clear();
        } else {
          writeSessionValue(_pendingOwnerKey, identity);
          if (session != null) writeSessionValue(_pendingSessionKey, session);
        }
      }
      var network = const MemberNetwork();
      if (identity != null) {
        try {
          network = await _api.network();
        } on LiveApiException catch (error) {
          if (error.code != 'invitation_required' &&
              error.code != 'membership_required') {
            rethrow;
          }
          _entering = true;
        }
      }
      if (!mounted ||
          generation != _loadGeneration ||
          session != pushSessionId(widget.client)) {
        return;
      }
      try {
        if (identity != null &&
            _credential != null &&
            !_deferInvitation &&
            (network.own != null || readSessionValue(_finalizeKey) == '1')) {
          final existingOnly =
              readSessionValue('paul.live.sign-in-existing.v1') == '1';
          if (network.own == null && !existingOnly && _draft != null) {
            final latest = await OnboardingDraftStore(
              preferences: widget.draftPreferences,
            ).read();
            if (latest.hasData) _draft = latest;
          }
          if (!mounted || generation != _loadGeneration) return;
          await _api.redeem(
            _credential!,
            draft: existingOnly || network.own != null ? null : _draft,
          );
          await _clearPending();
          await OnboardingDraftStore(
            preferences: widget.draftPreferences,
          ).clear();
          network = await _api.network();
        }
      } on LiveApiException catch (error) {
        _error = error.toString();
        _invalidCredential = error.code == 'invalid_invitation';
        _acceptedInvite = false;
        _entering = true;
      }
      if (!mounted || generation != _loadGeneration) return;
      if (network.own == null && _network.own != null) {
        _navigator.currentState?.popUntil((route) => route.isFirst);
        _disposeChat();
        _disposeSearch();
        _profile?.dispose();
        _profile = null;
      }
      if (network.own == null && _push != null) {
        _pendingPushClick = null;
        _push?.dispose();
        _push = null;
        unawaited(_setPushIdentity(null));
      }
      _network = network;
      if (network.own != null && (_profile == null || !_profile!.loaded)) {
        final controller = ProfileController(
          SupabaseProfileStore(
            _api,
            identity!,
            initialProfile: network.own,
            initialSession: profileSession,
          ),
          offeringLimit: 5,
        );
        await controller.load();
        if (!mounted || generation != _loadGeneration) {
          controller.dispose();
          return;
        }
        _profile?.dispose();
        _profile = controller;
        final photo = pendingPlatformPhoto(
          ownerId: identity,
          destination: PhotoDestination.profile,
          targetId: identity,
        );
        if (photo != null) {
          controller.updatePhoto(photo);
          await controller.flush();
          if (!controller.hasUnsavedChanges) {
            completePlatformPhoto(
              ownerId: identity,
              destination: PhotoDestination.profile,
              targetId: identity,
              photo: photo,
            );
          }
          if (!mounted || generation != _loadGeneration) return;
        }
      } else if (network.own != null && _profile?.loaded == true) {
        await _profile!.refresh();
        if (!mounted || generation != _loadGeneration) return;
      }
      if (network.own != null && _profile?.loaded == true) {
        await _refreshCapabilities();
        if (!mounted || generation != _loadGeneration) return;
        _ensureChat();
        unawaited(_ensurePush());
        _search ??= SkillSearchController(
          widget.searchRepositoryFor?.call(identity!) ??
              SupabaseSkillSearchApi(widget.client, identity!),
        );
        if (!_search!.idle) unawaited(_search!.retry());
      }
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      if (error is LiveApiException &&
          (error.code == 'session_revoked' ||
              error.code == 'sign_in_required')) {
        _navigator.currentState?.popUntil((route) => route.isFirst);
        _disposeChat();
        _disposeSearch();
        _profile?.dispose();
        _profile = null;
        _network = const MemberNetwork();
        _pendingPushClick = null;
        _peerPhotos.clear();
        _entering = widget.purpose == AppPurpose.app;
        try {
          await widget.client.auth.signOut(scope: SignOutScope.local);
        } catch (_) {
          /* Local SDK state is already cleared. */
        }
      }
      _error = error is LiveApiException
          ? error.toString()
          : 'Could not load Paul. Check your connection and retry.';
      if (error is LiveApiException && error.code == 'invalid_invitation') {
        _acceptedInvite = false;
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
        unawaited(_drainPushClick());
      }
    }
  }

  Future<void> _setPushIdentity(String? userId) async {
    try {
      await _pushBrowser.identity(userId, pushSessionId(widget.client));
    } catch (_) {
      /* A supported browser can retry storage/worker failures in settings. */
    }
  }

  Future<void> _refreshCapabilities() async {
    final profile = _profile;
    final identity = _identity;
    final loadGeneration = _loadGeneration;
    if (profile == null || identity == null || !profile.loaded) return;
    final generation = ++_capabilityGeneration;
    try {
      final level = await _api.capabilities();
      if (!mounted ||
          generation != _capabilityGeneration ||
          loadGeneration != _loadGeneration ||
          identity != _identity ||
          widget.client.auth.currentUser?.id != identity) {
        return;
      }
      profile.setOfferingLimit(level.offeringLimit);
      setState(() {
        _capabilities = level;
      });
    } catch (_) {
      // Keep the last server-confirmed capabilities; failed refresh never grants
      // an unlock and cannot fabricate a P15 milestone.
    }
  }

  void _openQr() {
    final profile = _profile;
    if (profile == null ||
        !mounted ||
        widget.client.auth.currentUser?.id != _identity) {
      return;
    }
    unawaited(
      _navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              LiveQrView(profile: profile, issuer: _api, appUrl: widget.appUrl),
        ),
      ),
    );
  }

  Future<void> _ensurePush() async {
    final userId = _identity;
    final session = pushSessionId(widget.client);
    if (userId == null || session == null) return;
    if (_push?.repository.sessionId == session &&
        _push?.repository.userId == userId) {
      return;
    }
    _push?.dispose();
    final controller = PushController(
      _pushBrowser,
      widget.pushRepositoryFor?.call(userId, session) ??
          SupabasePushApi(widget.client, userId, session),
    );
    _push = controller;
    await controller.initialize();
    if (!mounted || !identical(_push, controller)) return;
    setState(() {});
    await _drainPushClick();
  }

  Future<void> _drainPushClick() async {
    final click = _pendingPushClick;
    final push = _push;
    if (click == null ||
        push == null ||
        !push.ready ||
        _loading ||
        _openingPush) {
      return;
    }
    _pendingPushClick = null;
    if (click.recipientId != _identity || !push.repository.current) return;
    final generation = _loadGeneration;
    bool current() =>
        mounted &&
        generation == _loadGeneration &&
        identical(_push, push) &&
        push.repository.current;
    _openingPush = true;
    try {
      final local = await _pushBrowser.inspect();
      if (!current() || !local.active || local.bindingId != click.bindingId) {
        return;
      }
      final route = await push.repository.resolve(click);
      if (!current()) return;
      _navigator.currentState?.popUntil((route) => route.isFirst);
      await WidgetsBinding.instance.endOfFrame;
      if (!current()) return;
      if (route.kind == 'community') {
        setState(() => _tab = 1);
        final controller = _ensureCommunity();
        unawaited(
          _navigator.currentState!.push<void>(
            MaterialPageRoute(
              builder: (_) => CommunityDetailView(
                controller: controller,
                requestId: route.requestId!,
                onMessage: _openChat,
                avatarFor: _peerAvatar,
              ),
            ),
          ),
        );
      } else if (route.kind == 'operator') {
        final admin = SupabaseAdminApi(widget.client, click.recipientId);
        final access = await admin.context();
        if (!current()) return;
        final profile = access.profiles
            .where(
              (profile) =>
                  profile.id == route.managedProfileId &&
                  profile.canReply &&
                  profile.disabledAt == null,
            )
            .firstOrNull;
        if (profile == null) throw const PushException('push_forbidden');
        unawaited(
          _navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => OperatorInboxView(
                repository: admin.operatorFor(profile.id),
                actorId: click.recipientId,
                profile: profile,
                initialConversationId: route.conversationId,
                senderAvatar: ManagedProfileAvatar(
                  repository: admin,
                  profile: profile,
                  size: 65,
                ),
              ),
            ),
          ),
        );
      } else {
        final threads = await _chat!.repository.list();
        if (!current()) return;
        final thread = threads
            .where((thread) => thread.id == route.conversationId)
            .firstOrNull;
        final origin = _homeContext;
        if (thread == null || origin == null || !origin.mounted) {
          throw const PushException('push_forbidden');
        }
        final opening = Completer<void>();
        unawaited(
          _openChat(
            origin,
            thread.peer,
            conversationId: thread.id,
            opening: opening,
          ),
        );
        await opening.future;
      }
    } catch (_) {
      if (current()) {
        _showMessage(
          'This notification is no longer available. Open your current chats.',
        );
      }
    } finally {
      _openingPush = false;
      if (_pendingPushClick != null) unawaited(_drainPushClick());
    }
  }

  void _ensureChat() {
    final identity = _identity;
    if (_chat != null || identity == null || _network.own == null) return;
    final chat = LiveChatController(
      widget.chatRepositoryFor?.call(identity) ??
          SupabaseChatApi(widget.client, identity),
      identity,
      drafts: createChatStateStore(_identity!),
    );
    _chat = chat;
    chat.onChanged = () {
      if (identical(chat, _chat)) unawaited(_refreshNetwork());
    };
    chat.onConnected = (_) {
      if (identical(chat, _chat)) unawaited(_refreshNetwork());
    };
    chat.onSendError = (error) {
      if (identical(chat, _chat) && error.code == 'new_contact_limit_reached') {
        unawaited(_refreshCapabilities());
      }
    };
    unawaited(
      chat.load().then((_) {
        if (!_resumed) chat.pause();
      }),
    );
  }

  void _disposeChat() {
    final chat = _chat;
    _chat = null;
    if (chat == null) return;
    chat.onChanged = null;
    chat.onConnected = null;
    chat.onSendError = null;
    chat.dispose();
    unawaited(chat.flushDrafts());
  }

  void _disposeSearch() {
    _search?.dispose();
    _search = null;
    _community?.dispose();
    _community = null;
  }

  CommunityController _ensureCommunity() {
    final existing = _community;
    if (existing != null) return existing;
    final controller = CommunityController(
      widget.communityRepositoryFor?.call(_identity!) ??
          SupabaseCommunityApi(widget.client, _identity!),
      drafts: createChatStateStore(_identity!),
    );
    _community = controller;
    unawaited(controller.refresh());
    return controller;
  }

  bool _setupOpen = false;
  Future<void> _showContinueSetup() async {
    if (_setupOpen || _network.own == null) return;
    _setupOpen = true;
    try {
      await _refreshCapabilities();
      final level = _capabilities;
      final context = _homeContext;
      if (!mounted ||
          context == null ||
          !context.mounted ||
          level == null ||
          level.invitedRegistrations >= 10) {
        return;
      }
      final invite = await showContinueSetupDialog(
        context,
        invitedRegistrations: level.invitedRegistrations,
      );
      if (mounted && invite == true) _openQr();
    } finally {
      _setupOpen = false;
    }
  }

  Future<void> _askCommunity(String skill) async {
    if (_identity == null || _network.own == null) return;
    await _navigator.currentState!.push<void>(
      MaterialPageRoute(
        builder: (_) => CommunityComposeView(
          controller: _ensureCommunity(),
          onInvite: _openQr,
          onPublishLimit: () => unawaited(_showContinueSetup()),
          initialSkill: skill,
        ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (_resumed) {
      unawaited(_push?.refresh());
      _chat?.resume();
      unawaited(_refreshCapabilities());
      unawaited(_profile?.refresh());
    } else {
      _chat?.pause();
      unawaited(_chat?.flushDrafts());
    }
  }

  Future<bool> _refreshNetwork() {
    final running = _networkRefresh;
    if (running != null) return running;
    final operation = _fetchNetwork();
    _networkRefresh = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_networkRefresh, operation)) _networkRefresh = null;
      }),
    );
    return operation;
  }

  Future<bool> _fetchNetwork() async {
    final identity = _identity;
    final session = _authSession;
    final generation = _loadGeneration;
    final chat = _chat;
    try {
      if (identity == null || chat == null) return false;
      final next = await _api.network();
      if (!mounted ||
          identity != _identity ||
          generation != _loadGeneration ||
          !identical(chat, _chat) ||
          session != pushSessionId(widget.client) ||
          widget.client.auth.currentUser?.id != identity) {
        return false;
      }
      if (next.own == null) {
        unawaited(_load());
        return false;
      }
      final previous = _network.contacts.map((member) => member.id).toSet();
      final added = next.contacts
          .where((member) => !previous.contains(member.id))
          .map((member) => member.id)
          .toSet();
      setState(() => _network = next);
      unawaited(_refreshCapabilities());
      if (added.isNotEmpty ||
          previous.any(
            (id) => !next.contacts.any((member) => member.id == id),
          )) {
        unawaited(_search?.retry());
      }
      final active = chat.conversations
          .where((thread) => thread.id == chat.activeConversationId)
          .firstOrNull;
      if (_resumed && active != null && added.contains(active.peer.id)) {
        _showMessage('You’re connected!');
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  void _showMessage(String message) {
    final context = _navigator.currentState?.overlay?.context;
    if (!mounted || context == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _peerAvatar(ChatPeer peer, {double size = 48}) {
    if (peer.id == _identity) {
      return ProfileAvatar(photo: _profile?.profile.photo, size: size);
    }
    final member = _network.contacts
        .where((member) => member.id == peer.id)
        .firstOrNull;
    final path = member != null ? member.avatarPath : peer.avatarPath;
    if (path == null || peer.deletedAt != null) {
      _peerPhotos.remove(peer.id);
      return ProfileAvatar(size: size);
    }
    var cached = _peerPhotos[peer.id];
    if (cached == null || cached.path != path) {
      cached = (
        path: path,
        photo: widget.client.storage.from('avatars').download(path),
      );
      _peerPhotos[peer.id] = cached;
    }
    return FutureBuilder<Uint8List?>(
      key: ValueKey('peer-avatar-$_identity-${peer.id}-$path'),
      future: cached.photo,
      builder: (_, snapshot) => ProfileAvatar(photo: snapshot.data, size: size),
    );
  }

  Future<void> _openChat(
    BuildContext origin,
    ChatPeer peer, {
    String? conversationId,
    Completer<void>? opening,
  }) async {
    final chat = _chat;
    final profile = _profile;
    final identity = _identity;
    final generation = _loadGeneration;
    final session = _authSession;
    if (chat == null ||
        profile == null ||
        identity == null ||
        peer.id == identity ||
        _openingChat) {
      opening?.complete();
      return;
    }
    _openingChat = true;
    try {
      if (!chat.loaded) await chat.prepare();
      if (!mounted ||
          !origin.mounted ||
          !identical(chat, _chat) ||
          generation != _loadGeneration ||
          session != pushSessionId(widget.client) ||
          identity != widget.client.auth.currentUser?.id ||
          ModalRoute.of(origin)?.isCurrent != true) {
        return;
      }
      if (!chat.loaded || chat.stateLoadFailed) {
        _showMessage(
          chat.error ?? 'Could not restore your chat drafts. Please retry.',
        );
        return;
      }
      final id = conversationId ?? await chat.resolvePeer(peer.id);
      if (!mounted ||
          !origin.mounted ||
          id == null ||
          !identical(chat, _chat) ||
          generation != _loadGeneration ||
          session != pushSessionId(widget.client) ||
          identity != widget.client.auth.currentUser?.id ||
          ModalRoute.of(origin)?.isCurrent != true) {
        return;
      }
      bool current() =>
          mounted &&
          identical(profile, _profile) &&
          identical(chat, _chat) &&
          identity == widget.client.auth.currentUser?.id &&
          session == pushSessionId(widget.client);
      final updates = Listenable.merge([profile, _networkUpdates]);
      final route = _navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => !current()
              ? const SizedBox.shrink()
              : ListenableBuilder(
                  listenable: updates,
                  builder: (_, _) => !current()
                      ? const SizedBox.shrink()
                      : LiveChatView(
                          key: ValueKey('$identity:$id'),
                          controller: chat,
                          conversationId: id,
                          peer: peer,
                          ownAvatar: ProfileAvatar(
                            photo: profile.profile.photo,
                            size: 65,
                          ),
                          peerAvatar: _peerAvatar(peer, size: 65),
                          onInvite: _openQr,
                          onNewRecipientLimit: () =>
                              unawaited(_showContinueSetup()),
                        ),
                ),
        ),
      );
      unawaited(chat.openConversation(id));
      opening?.complete();
      await route;
    } finally {
      if (opening != null && !opening.isCompleted) opening.complete();
      if (identical(chat, _chat)) {
        chat.closeConversation();
        _openingChat = false;
      }
    }
  }

  Future<void> _disconnect(BuildContext context, MemberProfile member) async {
    final chat = _chat;
    final identity = _identity;
    if (chat == null || identity == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => LiveDisconnectDialog(
        repository: chat.repository,
        userId: identity,
        peer: ChatPeer(
          id: member.id,
          name: member.profile.name,
          occupation: member.profile.occupation,
        ),
      ),
    );
    if (confirmed != true ||
        !mounted ||
        !context.mounted ||
        !identical(chat, _chat) ||
        identity != widget.client.auth.currentUser?.id) {
      return;
    }
    final refreshed = await _refreshNetwork();
    if (!mounted || !context.mounted || !identical(chat, _chat)) return;
    if (ModalRoute.of(context)?.isCurrent == true) Navigator.of(context).pop();
    _showMessage(
      !refreshed
          ? 'Removal request completed. Refresh Contacts to check the latest state.'
          : _network.contacts.any((peer) => peer.id == member.id)
          ? 'The connection is still active. Review it before another removal.'
          : 'Connection deleted',
    );
  }

  void _beginEntry({bool fromDraft = false}) {
    if (fromDraft) {
      writeSessionValue(_entryReturnKey, 'draft');
    } else {
      removeSessionValue(_entryReturnKey);
    }
    _navigator.currentState?.popUntil((route) => route.isFirst);
    setState(() {
      _entering = true;
      _editingGuestDraft = false;
    });
    if (widget.client.auth.currentUser != null) unawaited(_load());
  }

  void _editGuestDraft() {
    writeSessionValue(_entryReturnKey, 'editing');
    _entryGeneration++;
    removeSessionValue(_finalizeKey);
    setState(() {
      _callbackFailure = false;
      _editingGuestDraft = true;
      _entering = false;
      _acceptedInvite = false;
    });
  }

  void _continueGuestDraft(UserProfile draft) {
    _draft = draft;
    _beginEntry(fromDraft: true);
  }

  void _backFromEntry() {
    if (readSessionValue(_entryReturnKey) != 'draft') {
      _backToGuest();
      return;
    }
    _editGuestDraft();
    setState(() => _checking = false);
  }

  void _backToGuest() {
    if (widget.purpose == AppPurpose.app) {
      _entryGeneration++;
      removeSessionValue(_finalizeKey);
      setState(() {
        _entering = true;
        _acceptedInvite = false;
        _checking = false;
      });
      return;
    }
    removeSessionValue(_entryReturnKey);
    _entryGeneration++;
    removeSessionValue(_finalizeKey);
    setState(() {
      _callbackFailure = false;
      _entering = false;
      _editingGuestDraft = false;
      _acceptedInvite = false;
      _checking = false;
    });
  }

  Future<void> _accept(String credential) async {
    if (_checking) return;
    final generation = ++_entryGeneration;
    final identity = widget.client.auth.currentUser?.id;
    setState(() {
      _checking = true;
      _error = null;
      _invalidCredential = false;
    });
    try {
      final value = credential.trim();
      await _api.check(value);
      if (!mounted ||
          generation != _entryGeneration ||
          identity != widget.client.auth.currentUser?.id) {
        return;
      }
      writeSessionValue(_inviteKey, value);
      _resumeInvitation();
      setState(() {
        _callbackFailure = false;
        _credential = value;
        _acceptedInvite = true;
      });
      unawaited(_refreshAuthProviders());
    } catch (error) {
      if (mounted && generation == _entryGeneration) {
        setState(() {
          _invalidCredential =
              error is LiveApiException && error.code == 'invalid_invitation';
          _error = error is LiveApiException
              ? error.toString()
              : 'Could not check the code. Please retry.';
        });
      }
    } finally {
      if (mounted && generation == _entryGeneration) {
        setState(() => _checking = false);
      }
    }
  }

  ({bool google, bool apple})? _providers;
  OAuthProvider _onboardingProvider = OAuthProvider.google;
  Future<void> _refreshAuthProviders() async {
    try {
      final providers =
          await widget.loadAuthProviders?.call() ??
          (google: widget.googleEnabled, apple: widget.appleEnabled);
      if (mounted) setState(() => _providers = providers);
    } catch (_) {
      /* A later explicit action retries the provider settings. */
    }
  }

  Future<OAuthProvider?> _chooseProvider(BuildContext context) async {
    if (_choosingProvider) return null;
    _choosingProvider = true;
    final generation = _entryGeneration;
    try {
      final providers =
          await widget.loadAuthProviders?.call() ??
          (google: widget.googleEnabled, apple: widget.appleEnabled);
      if (!context.mounted || generation != _entryGeneration) return null;
      if (providers.google && !providers.apple) return OAuthProvider.google;
      if (providers.apple && !providers.google) return OAuthProvider.apple;
      if (!providers.google && !providers.apple) return null;
      return await showDialog<OAuthProvider>(
        context: context,
        builder: (dialogContext) => Dialog(
          backgroundColor: const Color(0xFFF4F4F4),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: MobileAuthActions(
              onGoogle: () =>
                  Navigator.pop(dialogContext, OAuthProvider.google),
              onApple: () => Navigator.pop(dialogContext, OAuthProvider.apple),
            ),
          ),
        ),
      );
    } finally {
      _choosingProvider = false;
    }
  }

  Future<void> _signIn(OAuthProvider provider) async {
    removeSessionValue(_pendingOwnerKey);
    removeSessionValue(_pendingSessionKey);
    final opened = await widget.client.auth.signInWithOAuth(
      provider,
      authScreenLaunchMode: kIsWeb
          ? LaunchMode.platformDefault
          : LaunchMode.externalApplication,
      redirectTo: !kIsWeb
          ? 'app.paul://login-callback'
          : widget.appUrl
                .replace(queryParameters: {'auth': 'callback'}, fragment: '')
                .toString(),
    );
    if (!opened) {
      throw const OnboardingSubmissionException(
        'Could not open sign-in. Please try again.',
      );
    }
  }

  Future<void> _complete(
    BuildContext context,
    UserProfile draft, {
    OAuthProvider? provider,
  }) async {
    try {
      if (_credential == null) {
        throw const LiveApiException('invalid_invitation');
      }
      _draft = draft;
      writeSessionValue(_draftKey, draft.encode());
      await _api.check(_credential!);
      if (widget.client.auth.currentUser == null) {
        if (!context.mounted) {
          throw const OnboardingSubmissionException(
            'Please try again. Your profile draft is saved.',
          );
        }
        final selected = provider ?? await _chooseProvider(context);
        if (selected == null) {
          throw const OnboardingSubmissionException(
            'Sign-in was cancelled. Your profile draft is saved.',
          );
        }
        writeSessionValue(_finalizeKey, '1');
        await _signIn(selected);
        // The browser now navigates. The restored host finalizes the saved
        // snapshot after OAuth. Opening OAuth alone is never registration success.
        if (!kIsWeb) {
          final result = Completer<void>();
          late final StreamSubscription<AuthState> subscription;
          subscription = widget.client.auth.onAuthStateChange.listen(
            (state) {
              if (state.session != null && !result.isCompleted) {
                result.complete();
              }
            },
            onError: (Object error) {
              if (!result.isCompleted) result.completeError(error);
            },
          );
          try {
            if (widget.client.auth.currentSession == null) {
              await result.future.timeout(const Duration(minutes: 3));
            }
            await _load();
            if (_network.own != null) return;
          } finally {
            await subscription.cancel();
          }
        } else {
          await Future<void>.delayed(const Duration(seconds: 30));
        }
        throw const OnboardingSubmissionException(
          'Sign-in did not finish. Your profile draft is saved. Please try again.',
        );
      }
      await _api.redeem(_credential!, draft: draft);
      await _clearPending();
      await _load();
    } on LiveApiException catch (error) {
      removeSessionValue(_finalizeKey);
      if (error.code == 'invalid_invitation' && mounted) {
        setState(() {
          _acceptedInvite = false;
          _invalidCredential = true;
          _error = error.toString();
        });
      }
      throw OnboardingSubmissionException(error.toString());
    } on OnboardingSubmissionException {
      removeSessionValue(_finalizeKey);
      rethrow;
    } catch (_) {
      removeSessionValue(_finalizeKey);
      throw const OnboardingSubmissionException(
        'Could not complete sign-in. Your profile draft is saved. Please retry.',
      );
    }
  }

  Future<void> _logout() async {
    if (_signingOut) return;
    _signingOut = true;
    _pendingPushClick = null;
    _entryGeneration++;
    _entering = false;
    _editingGuestDraft = false;
    try {
      final profile = _profile;
      if (profile != null && !await profile.saveBeforeLeaving()) return;
      await _push?.disable();
      await widget.client.auth.signOut(scope: SignOutScope.local);
      await _clearPending();
      await OnboardingDraftStore(preferences: widget.draftPreferences).clear();
      if (mounted) await _load();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not sign out. Check your connection and retry.',
        );
      }
    } finally {
      _signingOut = false;
    }
  }

  Future<void> _openSearchProfile(SkillSearchHit hit) async {
    final search = _search;
    final identity = _identity;
    final generation = _loadGeneration;
    MemberProfile member;
    try {
      member = await _api.member(hit.id);
    } catch (_) {
      if (mounted && identity == _identity && generation == _loadGeneration) {
        _showMessage(
          'Could not open this profile. It may no longer be available.',
        );
      }
      return;
    }
    if (!mounted ||
        identity != _identity ||
        generation != _loadGeneration ||
        !identical(search, _search) ||
        widget.client.auth.currentUser?.id != identity) {
      return;
    }
    await _openProfile(member);
    if (mounted && identity == _identity && generation == _loadGeneration) {
      await search?.retry();
    }
  }

  Widget _searchAvatar(SkillSearchHit hit) {
    if (hit.id == _identity) {
      return ProfileAvatar(photo: _profile?.profile.photo, size: 65);
    }
    return _SearchProfileAvatar(
      key: ValueKey('search-avatar-$_identity-${hit.id}'),
      api: _api,
      profileId: hit.id,
    );
  }

  Future<void> _openProfile(MemberProfile member) async {
    final identity = _identity;
    final generation = _loadGeneration;
    final controller = _profile;
    if (identity == null || controller == null) return;
    try {
      final photo = await _api.photo(member);
      if (!mounted ||
          identity != _identity ||
          generation != _loadGeneration ||
          widget.client.auth.currentUser?.id != identity ||
          !identical(controller, _profile)) {
        return;
      }
      final own = member.id == identity;
      await _navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => ListenableBuilder(
            listenable: Listenable.merge([controller, _networkUpdates]),
            builder: (context, _) => PublicProfileView(
              profile: own ? controller.profile : member.profile,
              avatar: ProfileAvatar(
                photo: own ? controller.profile.photo : photo,
                size: 144,
              ),
              contactCount: own
                  ? _network.contacts.length
                  : member.contactCount,
              onChat: own
                  ? null
                  : () => unawaited(
                      _openChat(
                        context,
                        ChatPeer(
                          id: member.id,
                          name: member.profile.name,
                          occupation: member.profile.occupation,
                          avatarPath: member.avatarPath,
                        ),
                      ),
                    ),
              onDisconnect:
                  !own && _network.contacts.any((peer) => peer.id == member.id)
                  ? () => unawaited(_disconnect(context, member))
                  : null,
              onEdit: own
                  ? () {
                      Navigator.of(context).pop();
                      unawaited(_editProfile());
                    }
                  : null,
            ),
          ),
        ),
      );
    } catch (_) {
      if (mounted && identity == _identity && generation == _loadGeneration) {
        setState(
          () => _error =
              'Could not open this profile. Check your connection and retry.',
        );
      }
    }
  }

  Future<void> _editProfile() async {
    if (mounted) setState(() => _tab = 3);
    await _refreshCapabilities();
  }

  Future<void> _deleteAccount() async {
    final identity = _identity;
    final origin = _homeContext;
    if (identity == null || origin == null || !origin.mounted) return;
    if (!await confirmProfileDeletion(origin)) return;
    if (!mounted || widget.client.auth.currentUser?.id != identity) return;
    await _profile?.flush();
    await _deletions.begin(identity);
    if (mounted && _deletions.loadError != null) {
      _showMessage(_deletions.loadError!);
    }
  }

  Future<void> _signInDeletionRecovery(BuildContext context) async {
    try {
      if (widget.recoverSignIn != null) {
        await widget.recoverSignIn!();
        return;
      }
      final provider = await _chooseProvider(context);
      if (provider != null && mounted) await _signIn(provider);
    } catch (_) {
      if (mounted) {
        _showMessage(
          'Could not open sign-in. Your deletion recovery is saved. Retry.',
        );
      }
    }
  }

  Future<void> _deleteManaged(ManagedProfile profile) async {
    final identity = _identity;
    final origin = _navigator.currentContext;
    if (identity == null || origin == null || profile.updatedAt == null) return;
    if (!await confirmProfileDeletion(origin, name: profile.name)) return;
    if (!mounted || widget.client.auth.currentUser?.id != identity) return;
    final record = await _deletions.begin(
      identity,
      profileId: profile.id,
      updatedAt: profile.updatedAt,
    );
    if (!mounted || widget.client.auth.currentUser?.id != identity) return;
    if (record == null) {
      _showMessage(_deletions.loadError ?? 'Could not start deletion. Retry.');
      return;
    }
    await _navigator.currentState!.push<void>(
      MaterialPageRoute(
        builder: (context) => DeletionStatusView(
          controller: _deletions,
          record: record,
          onDone: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  Widget _home(BuildContext context) {
    _homeContext = context;
    final deletion = _deletions.records
        .where(
          (record) =>
              record.self && (_identity == null || record.actorId == _identity),
        )
        .firstOrNull;
    if (deletion != null) {
      return DeletionStatusView(
        controller: _deletions,
        record: deletion,
        onSignIn: () => unawaited(_signInDeletionRecovery(context)),
      );
    }
    if (_identity != null &&
        !_loading &&
        _network.own == null &&
        _error != null &&
        !_entering &&
        !_acceptedInvite) {
      return _EntryFrame(
        child: Center(
          key: const Key('member-startup-error'),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error!, textAlign: TextAlign.center),
                TextButton(
                  key: const Key('member-startup-retry'),
                  onPressed: _load,
                  child: const Text('Retry'),
                ),
                TextButton(onPressed: _logout, child: const Text('Sign out')),
              ],
            ),
          ),
        ),
      );
    }
    if (widget.purpose != AppPurpose.app &&
        !_entering &&
        _network.own == null &&
        (_identity == null || !_loading)) {
      if (_editingGuestDraft) {
        return OnboardingFlow(
          preferences: widget.draftPreferences,
          initialDraft: _draft,
          onBack: _backToGuest,
          onContinueToRegistration: _continueGuestDraft,
        );
      }
      if (widget.publicPreviewRepository != null) {
        return PublicGuestPreview(
          repository: widget.publicPreviewRepository!,
          browsingState: _publicBrowsing,
          onRequireSignIn: _beginEntry,
          onEditProfile: _editGuestDraft,
        );
      }
      return GuestPreview(
        onRequireSignIn: _beginEntry,
        onEditProfile: _editGuestDraft,
      );
    }
    if (_loading) {
      return const _EntryFrame(
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_network.own != null && _profile?.loaded == true) {
      return _LiveContacts(
        profile: _profile!,
        network: _network,
        api: _api,
        error: _visibleError,
        onRefresh: _load,
        onProfile: _openProfile,
        chat: _chat!,
        onChat: (thread) => unawaited(
          _openChat(context, thread.peer, conversationId: thread.id),
        ),
        chatAvatar: (peer) => _peerAvatar(peer, size: 65),
        search: _search!,
        onSearchProfile: _openSearchProfile,
        community: _ensureCommunity(),
        onCommunityMessage: _openChat,
        communityAvatar: (peer) => _peerAvatar(peer, size: 65),
        onAskCommunity: (skill) => unawaited(_askCommunity(skill)),
        searchAvatar: _searchAvatar,
        selectedTab: _tab,
        onSelected: (value) {
          unawaited(_profile!.flush());
          setState(() => _tab = value);
          if (value == 0) unawaited(_refreshNetwork());
          if (value == 2) unawaited(_chat?.refresh());
          if (value == 3) unawaited(_refreshCapabilities());
        },
        adminRepository: SupabaseAdminApi(widget.client, _identity!),
        onLogout: _logout,
        onDelete: () => unawaited(_deleteAccount()),
        onDeleteManaged: _deleteManaged,
        deletionRecovery: Column(
          children: [
            if (_deletions.loadError != null)
              TextButton(
                onPressed: _deletions.load,
                child: const Text('Retry account deletion recovery'),
              ),
            for (final record in _deletions.records.where(
              (item) => !item.self && item.actorId == _identity,
            ))
              TextButton(
                onPressed: () => _navigator.currentState!.push<void>(
                  MaterialPageRoute(
                    builder: (context) => DeletionStatusView(
                      controller: _deletions,
                      record: record,
                      onDone: () => Navigator.of(context).pop(),
                    ),
                  ),
                ),
                child: const Text('Check user deletion'),
              ),
          ],
        ),
        onOfferingLimit: () => unawaited(_showContinueSetup()),
        push: _push,
        onQr: _openQr,
        onDismissInvite: () async {
          if (_callbackFailure) {
            setState(() => _callbackFailure = false);
            return;
          }
          await _clearPending();
          await _load();
        },
      );
    }
    if (_network.own != null && _profile?.loadFailed == true) {
      return _EntryFrame(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_profile!.error!, textAlign: TextAlign.center),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_acceptedInvite) {
      return OnboardingFlow(
        preferences: widget.draftPreferences,
        initialDraft: _draft,
        onBack: _backToGuest,
        pickPhoto: () => pickPlatformPhoto(
          ownerId: onboardingPhotoOwner(),
          destination: PhotoDestination.onboarding,
          targetId: onboardingPhotoOwner(),
        ),
        onPhotoPersisted: (photo) => completePlatformPhoto(
          ownerId: onboardingPhotoOwner(),
          destination: PhotoDestination.onboarding,
          targetId: onboardingPhotoOwner(),
          photo: photo,
        ),
        onComplete: (draft) =>
            _complete(context, draft, provider: _onboardingProvider),
        registrationActions: (submit) => MobileAuthActions(
          onGoogle: _providers?.google == false
              ? null
              : submit == null
              ? null
              : () {
                  _onboardingProvider = OAuthProvider.google;
                  submit();
                },
          onApple: _providers?.apple != true
              ? null
              : submit == null
              ? null
              : () {
                  _onboardingProvider = OAuthProvider.apple;
                  submit();
                },
        ),
      );
    }
    return InvitationEntryView(
      pendingCredential: _credential,
      onBack: widget.purpose == AppPurpose.app ? null : _backFromEntry,
      invalidCode: _invalidCredential,
      errorText: _invalidCredential ? null : _visibleError,
      onRetry: !_callbackFailure && !_invalidCredential && _error != null
          ? _load
          : null,
      checking: _checking,
      onJoin: (value) => unawaited(_accept(value)),
      onCodeChanged: (_) {
        if (_error != null || _invalidCredential) {
          setState(() {
            _error = null;
            _invalidCredential = false;
          });
        }
      },
      onSignIn: (credential) async {
        if (_checking) return;
        final generation = _entryGeneration;
        removeSessionValue(_finalizeKey);
        setState(() => _checking = true);
        try {
          await _api.check(credential.trim());
          if (!mounted || generation != _entryGeneration) return;
          _credential = credential.trim();
          writeSessionValue(_inviteKey, _credential!);
          writeSessionValue('paul.live.sign-in-existing.v1', '1');
          _resumeInvitation();
          if (!context.mounted) return;
          final provider = await _chooseProvider(context);
          if (provider == null || !mounted) return;
          writeSessionValue(_finalizeKey, '1');
          await _signIn(provider);
        } catch (error) {
          if (mounted && generation == _entryGeneration) {
            setState(() {
              _invalidCredential =
                  error is LiveApiException &&
                  error.code == 'invalid_invitation';
              _error = error is LiveApiException
                  ? error.toString()
                  : 'Could not open sign-in. Please try again.';
            });
          }
        } finally {
          if (mounted && generation == _entryGeneration) {
            setState(() => _checking = false);
          }
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: _navigator,
    title: 'Paul',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'NotoSans',
      scaffoldBackgroundColor: const Color(0xFFF4F4F4),
      colorScheme: ColorScheme.fromSeed(
        seedColor: _blue,
        surface: const Color(0xFFF4F4F4),
      ),
    ),
    home: ListenableBuilder(
      listenable: _deletions,
      builder: (context, _) => _home(context),
    ),
  );

  @override
  void dispose() {
    _loadGeneration++;
    _deletions.removeListener(_purgeDeletedLocalData);
    _deletions.dispose();
    unawaited(_auth.cancel());
    unawaited(_stopPlatformLinks?.call());
    unawaited(_pushClicks.cancel());
    _push?.dispose();
    if (widget.pushBrowser == null) _pushBrowser.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _disposeChat();
    _disposeSearch();
    _networkUpdates.dispose();
    _profile?.dispose();
    super.dispose();
  }
}

class _EntryFrame extends StatelessWidget {
  const _EntryFrame({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 402),
          child: child,
        ),
      ),
    ),
  );
}

class _LiveContacts extends StatelessWidget {
  const _LiveContacts({
    required this.profile,
    required this.network,
    required this.api,
    required this.onRefresh,
    required this.onProfile,
    required this.onLogout,
    required this.onDelete,
    required this.onDeleteManaged,
    required this.deletionRecovery,
    required this.onOfferingLimit,
    this.push,
    required this.adminRepository,
    required this.onQr,
    required this.onDismissInvite,
    required this.selectedTab,
    required this.onSelected,
    required this.chat,
    required this.onChat,
    required this.chatAvatar,
    required this.search,
    required this.onSearchProfile,
    required this.searchAvatar,
    required this.community,
    required this.onCommunityMessage,
    required this.communityAvatar,
    required this.onAskCommunity,
    this.error,
  });
  final ProfileController profile;
  final MemberNetwork network;
  final LiveApi api;
  final Future<void> Function() onRefresh;
  final Future<void> Function(MemberProfile) onProfile;
  final VoidCallback onLogout;
  final VoidCallback onDelete;
  final Future<void> Function(ManagedProfile) onDeleteManaged;
  final Widget deletionRecovery;
  final VoidCallback onOfferingLimit;
  final PushController? push;
  final AdminRepository adminRepository;
  final VoidCallback onQr;
  final VoidCallback onDismissInvite;
  final String? error;
  final int selectedTab;
  final ValueChanged<int> onSelected;
  final LiveChatController chat;
  final ValueChanged<ChatSummary> onChat;
  final Widget Function(ChatPeer) chatAvatar;
  final SkillSearchController search;
  final Future<void> Function(SkillSearchHit) onSearchProfile;
  final Widget Function(SkillSearchHit) searchAvatar;
  final CommunityController community;
  final CommunityMessage onCommunityMessage;
  final Widget Function(ChatPeer) communityAvatar;
  final ValueChanged<String> onAskCommunity;

  @override
  Widget build(BuildContext context) => _EntryFrame(
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 70, 28, 0),
          child: ProfileNavigation(
            selected: selectedTab,
            onSelected: onSelected,
            enabledTabs: const {0, 1, 2, 3},
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              children: [
                Text(
                  error!,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
                TextButton(
                  onPressed: onDismissInvite,
                  child: const Text('Continue to Contacts'),
                ),
              ],
            ),
          ),
        if (selectedTab == 1)
          Expanded(
            child: CommunityFeedView(
              controller: community,
              onMessage: onCommunityMessage,
              onInvite: onQr,
              avatarFor: communityAvatar,
              embedded: true,
            ),
          )
        else if (selectedTab == 2)
          Expanded(
            child: LiveChatList(
              controller: chat,
              onOpen: onChat,
              avatarFor: chatAvatar,
            ),
          )
        else if (selectedTab == 3)
          Expanded(
            child: ListenableBuilder(
              listenable: profile,
              builder: (context, _) => Column(
                children: [
                  if (profile.error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              profile.error!,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          TextButton(
                            onPressed: profile.hasConflict
                                ? () => reviewProfileConflict(context, profile)
                                : profile.refreshFailed
                                ? profile.refresh
                                : profile.flush,
                            child: Text(
                              profile.hasConflict ? 'Review changes' : 'Retry',
                            ),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: ProfileEditor(
                      controller: profile,
                      pickPhoto: () => pickPlatformPhoto(
                        ownerId: network.own!.id,
                        destination: PhotoDestination.profile,
                        targetId: network.own!.id,
                      ),
                      onPhotoPersisted: (photo) => completePlatformPhoto(
                        ownerId: network.own!.id,
                        destination: PhotoDestination.profile,
                        targetId: network.own!.id,
                        photo: photo,
                      ),
                      onInvite: onQr,
                      onOfferingLimit: onOfferingLimit,
                      onDelete: onDelete,
                      occupationRequired: false,
                      onViewProfile: () => onProfile(network.own!),
                      footer: Padding(
                        padding: const EdgeInsets.only(top: 40),
                        child: Column(
                          children: [
                            AdminEntry(
                              key: ValueKey(network.own!.id),
                              repository: adminRepository,
                              onDeleteProfile: onDeleteManaged,
                            ),
                            deletionRecovery,
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: Stack(
              children: [
                SkillSearchView(
                  controller: search,
                  onOpen: onSearchProfile,
                  avatarFor: searchAvatar,
                  onAskCommunity: onAskCommunity,
                  contacts: RefreshIndicator(
                    onRefresh: onRefresh,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(37.5, 26, 37.5, 80),
                      children: [
                        ListenableBuilder(
                          listenable: profile,
                          builder: (context, _) => ContactRow(
                            name: profile.profile.name,
                            occupation: profile.profile.occupation,
                            avatar: ProfileAvatar(
                              photo: profile.profile.photo,
                              size: 65,
                            ),
                            onOpen: () => onProfile(network.own!),
                          ),
                        ),
                        for (final member in network.contacts)
                          ContactRow(
                            key: ValueKey('${member.id}:${member.avatarPath}'),
                            name: member.profile.name,
                            occupation: member.profile.occupation,
                            avatar: chatAvatar(
                              ChatPeer(
                                id: member.id,
                                name: member.profile.name,
                                occupation: member.profile.occupation,
                                avatarPath: member.avatarPath,
                              ),
                            ),
                            onOpen: () => onProfile(member),
                          ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  right: 28,
                  bottom: 24,
                  child: ListenableBuilder(
                    listenable: search,
                    builder: (context, _) => search.idle
                        ? FloatingActionButton.small(
                            key: const Key('open-live-qr'),
                            tooltip: 'My QR code',
                            backgroundColor: _blue,
                            foregroundColor: Colors.white,
                            onPressed: onQr,
                            child: const Icon(Icons.qr_code_scanner, size: 23),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
                Positioned(
                  left: 28,
                  bottom: 24,
                  child: ListenableBuilder(
                    listenable: search,
                    builder: (context, _) => search.idle
                        ? IconButton(
                            tooltip: 'Refresh contacts',
                            onPressed: onRefresh,
                            icon: const Icon(Icons.refresh, color: _blue),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _SearchProfileAvatar extends StatefulWidget {
  const _SearchProfileAvatar({
    super.key,
    required this.api,
    required this.profileId,
  });
  final LiveApi api;
  final String profileId;
  @override
  State<_SearchProfileAvatar> createState() => _SearchProfileAvatarState();
}

class _SearchProfileAvatarState extends State<_SearchProfileAvatar> {
  late final _photo = _load();
  Future<Uint8List?> _load() async =>
      widget.api.photo(await widget.api.member(widget.profileId));
  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _photo,
    builder: (_, snapshot) => ProfileAvatar(photo: snapshot.data, size: 65),
  );
}
