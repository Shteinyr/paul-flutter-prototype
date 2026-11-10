import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart';
import '../admin/admin_api.dart';
import '../admin/admin_view.dart';
import '../onboarding/onboarding_draft_store.dart';
import '../onboarding/onboarding_flow.dart';
import '../profile/profile_controller.dart';
import '../profile/public_profile_view.dart';
import '../profile/user_profile.dart';
import 'browser_storage.dart';
import 'live_api.dart';
import 'live_qr_view.dart';
import 'guest_preview.dart';
import 'chat_api.dart';
import 'chat_controller.dart';
import 'live_chat_list.dart';
import 'live_chat_view.dart';
import 'live_disconnect_dialog.dart';

const _blue = Color(0xFF14679E);
const _inviteKey = 'paul.live.pending.invitation.v1';
const _draftKey = 'paul.live.pending.profile.v1';
const _finalizeKey = 'paul.live.pending.finalize.v1';

class PaulLiveApp extends StatefulWidget {
  const PaulLiveApp({
    super.key,
    required this.client,
    required this.appUrl,
    this.googleEnabled = false,
    this.appleEnabled = false,
    this.loadAuthProviders,
    this.authCallback = false,
    this.draftPreferences,
    this.chatRepositoryFor,
  });
  final SupabaseClient client;
  final Uri appUrl;
  final bool googleEnabled;
  final bool appleEnabled;
  final Future<({bool google, bool apple})> Function()? loadAuthProviders;
  final bool authCallback;
  final SharedPreferencesAsync? draftPreferences;
  final ChatRepository Function(String userId)? chatRepositoryFor;
  @override
  State<PaulLiveApp> createState() => _PaulLiveAppState();
}

class _PaulLiveAppState extends State<PaulLiveApp> with WidgetsBindingObserver {
  late final LiveApi _api;
  late final StreamSubscription<AuthState> _auth;
  final _navigator = GlobalKey<NavigatorState>();
  ProfileController? _profile;
  final _networkUpdates = ValueNotifier(const MemberNetwork());
  MemberNetwork get _network => _networkUpdates.value;
  set _network(MemberNetwork value) => _networkUpdates.value = value;
  LiveChatController? _chat;
  Future<bool>? _networkRefresh;
  bool _openingChat = false;
  bool _resumed = true;
  final _peerPhotos = <String, ({String? path, Future<Uint8List?> photo})>{};
  UserProfile? _draft;
  String? _credential;
  String? _identity;
  String? _error;
  bool _loading = true;
  bool _acceptedInvite = false;
  bool _entering = false;
  bool _choosingProvider = false;
  int _entryGeneration = 0;
  bool _checking = false;
  int _loadGeneration = 0;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _api = LiveApi(widget.client);
    final fragment = Uri.base.fragment;
    _credential = fragment.startsWith('invite=')
        ? fragment.substring(7)
        : readSessionValue(_inviteKey);
    if (_credential != null) writeSessionValue(_inviteKey, _credential!);
    clearInviteFromAddress();
    final draft = readSessionValue(_draftKey);
    if (draft != null) {
      try {
        _draft = UserProfile.decode(draft);
      } catch (_) {
        removeSessionValue(_draftKey);
      }
    }
    _identity = widget.client.auth.currentUser?.id;
    _entering = widget.authCallback && readSessionValue(_finalizeKey) == '1';
    if (!widget.authCallback) removeSessionValue(_finalizeKey);
    _auth = widget.client.auth.onAuthStateChange.listen(
      (event) {
        if (event.event == AuthChangeEvent.tokenRefreshed) return;
        unawaited(_load());
      },
      onError: (Object _) {
        removeSessionValue(_finalizeKey);
        if (mounted) {
          setState(() {
            _loading = false;
            _error =
                'Sign-in did not finish. Your profile draft is saved. Please try again.';
          });
        }
      },
    );
    unawaited(_load());
  }

  Future<void> _clearPending() async {
    removeSessionValue(_inviteKey);
    removeSessionValue(_draftKey);
    removeSessionValue(_finalizeKey);
    _credential = null;
    _draft = null;
    _acceptedInvite = false;
  }

  Future<void> _load() async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    final identity = widget.client.auth.currentUser?.id;
    setState(() {
      _loading = true;
      _error = null;
    });
    if (_identity != identity) {
      _navigator.currentState?.popUntil((route) => route.isFirst);
      _disposeChat();
      _networkRefresh = null;
      _peerPhotos.clear();
      _openingChat = false;
      _profile?.dispose();
      _profile = null;
      _network = const MemberNetwork();
      _tab = 0;
      if (_identity != null) {
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
    }
    if (!mounted ||
        generation != _loadGeneration ||
        widget.client.auth.currentUser?.id != identity) {
      return;
    }
    try {
      var network = identity == null
          ? const MemberNetwork()
          : await _api.network();
      if (!mounted || generation != _loadGeneration) return;
      try {
        if (_credential != null) {
          if (network.own != null) {
            await _api.redeem(_credential!);
            await _clearPending();
            network = await _api.network();
          } else if (widget.authCallback &&
              identity != null &&
              _draft != null &&
              readSessionValue(_finalizeKey) == '1') {
            try {
              final latest = await OnboardingDraftStore(
                preferences: widget.draftPreferences,
              ).read();
              if (latest.hasData) _draft = latest;
            } on FormatException {
              // A corrupt local draft can fall back to the submitted snapshot.
            }
            if (!mounted || generation != _loadGeneration) return;
            await _api.redeem(_credential!, draft: _draft);
            await _clearPending();
            await OnboardingDraftStore(
              preferences: widget.draftPreferences,
            ).clear();
            network = await _api.network();
          }
        }
      } on LiveApiException catch (error) {
        _error = error.toString();
        _acceptedInvite = false;
      }
      if (!mounted || generation != _loadGeneration) return;
      if (network.own == null && _network.own != null) {
        _navigator.currentState?.popUntil((route) => route.isFirst);
        _disposeChat();
        _profile?.dispose();
        _profile = null;
      }
      _network = network;
      if (network.own != null && (_profile == null || !_profile!.loaded)) {
        final controller = ProfileController(
          SupabaseProfileStore(_api, identity!),
        );
        await controller.load();
        if (!mounted || generation != _loadGeneration) {
          controller.dispose();
          return;
        }
        _profile?.dispose();
        _profile = controller;
      }
      if (network.own != null && _profile?.loaded == true) _ensureChat();
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      _error = error is LiveApiException
          ? error.toString()
          : 'Could not load Paul. Check your connection and retry.';
      if (error is LiveApiException && error.code == 'invalid_invitation') {
        _acceptedInvite = false;
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  void _ensureChat() {
    final identity = _identity;
    if (_chat != null || identity == null || _network.own == null) return;
    final chat = LiveChatController(
      widget.chatRepositoryFor?.call(identity) ??
          SupabaseChatApi(widget.client, identity),
      identity,
      drafts: SessionChatStateStore(),
    );
    _chat = chat;
    chat.onChanged = () {
      if (identical(chat, _chat)) unawaited(_refreshNetwork());
    };
    chat.onConnected = (_) {
      if (identical(chat, _chat)) unawaited(_refreshNetwork());
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
    chat.dispose();
    unawaited(chat.flushDrafts());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (_resumed) {
      _chat?.resume();
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
    final generation = _loadGeneration;
    final chat = _chat;
    try {
      if (identity == null || chat == null) return false;
      final next = await _api.network();
      if (!mounted ||
          identity != _identity ||
          generation != _loadGeneration ||
          !identical(chat, _chat) ||
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
    final member = _network.contacts
        .where((member) => member.id == peer.id)
        .firstOrNull;
    if (member == null) {
      _peerPhotos.remove(peer.id);
      return ProfileAvatar(size: size);
    }
    var cached = _peerPhotos[peer.id];
    if (cached == null || cached.path != member.avatarPath) {
      cached = (path: member.avatarPath, photo: _api.photo(member));
      _peerPhotos[peer.id] = cached;
    }
    return FutureBuilder<Uint8List?>(
      future: cached.photo,
      builder: (_, snapshot) => ProfileAvatar(photo: snapshot.data, size: size),
    );
  }

  Future<void> _openChat(
    BuildContext origin,
    ChatPeer peer, {
    String? conversationId,
  }) async {
    final chat = _chat;
    final profile = _profile;
    final identity = _identity;
    final generation = _loadGeneration;
    if (chat == null ||
        profile == null ||
        identity == null ||
        peer.id == identity ||
        _openingChat) {
      return;
    }
    _openingChat = true;
    try {
      if (!chat.loaded) await chat.load();
      if (!mounted ||
          !origin.mounted ||
          !identical(chat, _chat) ||
          generation != _loadGeneration ||
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
      final id = conversationId ?? await chat.openPeer(peer.id);
      if (conversationId != null) await chat.openConversation(conversationId);
      if (!mounted ||
          !origin.mounted ||
          id == null ||
          !identical(chat, _chat) ||
          generation != _loadGeneration ||
          identity != widget.client.auth.currentUser?.id ||
          ModalRoute.of(origin)?.isCurrent != true) {
        return;
      }
      await _navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => ListenableBuilder(
            listenable: Listenable.merge([profile, _networkUpdates]),
            builder: (_, _) => LiveChatView(
              key: ValueKey('$identity:$id'),
              controller: chat,
              conversationId: id,
              peer: peer,
              ownAvatar: ProfileAvatar(photo: profile.profile.photo, size: 48),
              peerAvatar: _peerAvatar(peer),
            ),
          ),
        ),
      );
    } finally {
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

  void _beginEntry() {
    _navigator.currentState?.popUntil((route) => route.isFirst);
    setState(() {
      _entering = true;
    });
    if (widget.client.auth.currentUser != null) unawaited(_load());
  }

  void _backToGuest() {
    _entryGeneration++;
    removeSessionValue(_finalizeKey);
    setState(() {
      _entering = false;
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
      setState(() {
        _credential = value;
        _acceptedInvite = true;
      });
    } catch (error) {
      if (mounted && generation == _entryGeneration) {
        setState(
          () => _error = error is LiveApiException
              ? error.toString()
              : 'Could not check the code. Please retry.',
        );
      }
    } finally {
      if (mounted && generation == _entryGeneration) {
        setState(() => _checking = false);
      }
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
      return await showDialog<OAuthProvider>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Sign in'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: providers.google
                    ? () => Navigator.pop(context, OAuthProvider.google)
                    : null,
                child: const Text('Continue with Google'),
              ),
              TextButton(
                onPressed: providers.apple
                    ? () => Navigator.pop(context, OAuthProvider.apple)
                    : null,
                child: const Text('Continue with Apple'),
              ),
              if (!providers.google && !providers.apple)
                const Text(
                  'Sign-in is being configured. Your profile draft is saved.',
                  style: TextStyle(fontSize: 12),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Back'),
            ),
          ],
        ),
      );
    } finally {
      _choosingProvider = false;
    }
  }

  Future<void> _signIn(OAuthProvider provider) async {
    final opened = await widget.client.auth.signInWithOAuth(
      provider,
      redirectTo: widget.appUrl
          .replace(queryParameters: {'auth': 'callback'}, fragment: '')
          .toString(),
    );
    if (!opened) {
      throw const OnboardingSubmissionException(
        'Could not open sign-in. Please try again.',
      );
    }
  }

  Future<void> _complete(BuildContext context, UserProfile draft) async {
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
        final provider = await _chooseProvider(context);
        if (provider == null) {
          throw const OnboardingSubmissionException(
            'Sign-in was cancelled. Your profile draft is saved.',
          );
        }
        writeSessionValue(_finalizeKey, '1');
        await _signIn(provider);
        // The browser now navigates. The restored host finalizes the saved
        // snapshot after OAuth. Opening OAuth alone is never registration success.
        await Future<void>.delayed(const Duration(seconds: 30));
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
    _entryGeneration++;
    _entering = false;
    try {
      await _profile?.flush();
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
    }
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
  }

  Widget _home(BuildContext context) {
    if (!_entering &&
        _network.own == null &&
        (_identity == null || !_loading)) {
      return GuestPreview(onRequireSignIn: _beginEntry);
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
        error: _error,
        onRefresh: _load,
        onProfile: _openProfile,
        chat: _chat!,
        onChat: (thread) => unawaited(
          _openChat(context, thread.peer, conversationId: thread.id),
        ),
        chatAvatar: (peer) => _peerAvatar(peer, size: 65),
        selectedTab: _tab,
        onSelected: (value) {
          unawaited(_profile!.flush());
          setState(() => _tab = value);
          if (value == 0) unawaited(_load());
          if (value == 2) unawaited(_chat?.refresh());
        },
        adminRepository: SupabaseAdminApi(widget.client, _identity!),
        onLogout: _logout,
        onQr: () => _navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => LiveQrView(
              profile: _profile!,
              issuer: _api,
              appUrl: widget.appUrl,
            ),
          ),
        ),
        onDismissInvite: () async {
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
        onComplete: (draft) => _complete(context, draft),
      );
    }
    return _JoinView(
      pendingCredential: _credential,
      onBack: _backToGuest,
      onClearInvite: () {
        removeSessionValue(_inviteKey);
        setState(() => _credential = null);
      },
      error: _error,
      checking: _checking,
      onAccept: _accept,
      onRetry:
          _error != null &&
              (_credential != null || widget.client.auth.currentUser != null)
          ? _load
          : null,
      onSignIn: () async {
        if (_checking) return;
        final generation = _entryGeneration;
        removeSessionValue(_finalizeKey);
        setState(() => _checking = true);
        try {
          final provider = await _chooseProvider(context);
          if (provider == null || !mounted) return;
          await _signIn(provider);
        } catch (_) {
          if (mounted && generation == _entryGeneration) {
            setState(
              () => _error = 'Could not open sign-in. Please try again.',
            );
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
    home: Builder(builder: _home),
  );

  @override
  void dispose() {
    _loadGeneration++;
    unawaited(_auth.cancel());
    WidgetsBinding.instance.removeObserver(this);
    _disposeChat();
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

class _JoinView extends StatefulWidget {
  const _JoinView({
    required this.onAccept,
    required this.onSignIn,
    required this.checking,
    this.error,
    this.onRetry,
    this.pendingCredential,
    required this.onBack,
    required this.onClearInvite,
  });
  final String? pendingCredential;
  final VoidCallback onBack;
  final VoidCallback onClearInvite;
  final Future<void> Function(String) onAccept;
  final VoidCallback onSignIn;
  final bool checking;
  final String? error;
  final VoidCallback? onRetry;
  @override
  State<_JoinView> createState() => _JoinViewState();
}

class _JoinViewState extends State<_JoinView> {
  final _code = TextEditingController();
  @override
  Widget build(BuildContext context) => _EntryFrame(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 37.5, vertical: 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 80),
          const Text(
            'Join',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 28,
              color: _blue,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 44),
          Text(
            widget.pendingCredential == null
                ? 'Enter your invitation code'
                : 'Continue with this invitation.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w300),
          ),
          const SizedBox(height: 24),
          if (widget.pendingCredential == null)
            TextField(
              key: const Key('invite-code-input'),
              controller: _code,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              maxLength: 8,
              enabled: !widget.checking,
              decoration: const InputDecoration(
                hintText: 'Invite code',
                counterText: '',
              ),
              onSubmitted: (value) =>
                  widget.checking ? null : unawaited(widget.onAccept(value)),
            ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: widget.checking
                ? null
                : () => widget.onAccept(widget.pendingCredential ?? _code.text),
            child: Text(widget.checking ? 'Checking…' : 'Join'),
          ),
          if (widget.error != null) ...[
            const SizedBox(height: 20),
            Text(
              widget.error!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
            if (widget.onRetry != null)
              TextButton(onPressed: widget.onRetry, child: const Text('Retry')),
          ],
          if (widget.pendingCredential != null)
            TextButton(
              onPressed: widget.checking ? null : widget.onClearInvite,
              child: const Text('Use another invitation code'),
            ),
          TextButton(
            onPressed: widget.onBack,
            child: const Text('Back to preview'),
          ),
          const SizedBox(height: 40),
          TextButton(
            onPressed: widget.checking ? null : widget.onSignIn,
            child: const Text('Already a member? Sign in'),
          ),
        ],
      ),
    ),
  );
  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }
}

class _LiveContacts extends StatelessWidget {
  const _LiveContacts({
    required this.profile,
    required this.network,
    required this.api,
    required this.onRefresh,
    required this.onProfile,
    required this.onLogout,
    required this.adminRepository,
    required this.onQr,
    required this.onDismissInvite,
    required this.selectedTab,
    required this.onSelected,
    required this.chat,
    required this.onChat,
    required this.chatAvatar,
    this.error,
  });
  final ProfileController profile;
  final MemberNetwork network;
  final LiveApi api;
  final Future<void> Function() onRefresh;
  final Future<void> Function(MemberProfile) onProfile;
  final VoidCallback onLogout;
  final AdminRepository adminRepository;
  final VoidCallback onQr;
  final VoidCallback onDismissInvite;
  final String? error;
  final int selectedTab;
  final ValueChanged<int> onSelected;
  final LiveChatController chat;
  final ValueChanged<ChatSummary> onChat;
  final Widget Function(ChatPeer) chatAvatar;

  @override
  Widget build(BuildContext context) => _EntryFrame(
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 70, 28, 0),
          child: ProfileNavigation(
            selected: selectedTab,
            onSelected: onSelected,
            enabledTabs: const {0, 2, 3},
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
        if (selectedTab == 2)
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
                            onPressed: profile.flush,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: ProfileEditor(
                      controller: profile,
                      occupationRequired: false,
                      onViewProfile: () => onProfile(network.own!),
                      footer: Padding(
                        padding: const EdgeInsets.only(top: 40),
                        child: Column(
                          children: [
                            AdminEntry(
                              key: ValueKey(network.own!.id),
                              repository: adminRepository,
                            ),
                            TextButton(
                              onPressed: onLogout,
                              child: const Text('Sign out'),
                            ),
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
                RefreshIndicator(
                  onRefresh: onRefresh,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(37.5, 47, 37.5, 80),
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
                        _MemberRow(
                          key: ValueKey('${member.id}:${member.avatarPath}'),
                          member: member,
                          api: api,
                          onOpen: () => onProfile(member),
                        ),
                    ],
                  ),
                ),
                Positioned(
                  right: 28,
                  bottom: 24,
                  child: FloatingActionButton.small(
                    key: const Key('open-live-qr'),
                    tooltip: 'My QR code',
                    backgroundColor: _blue,
                    foregroundColor: Colors.white,
                    onPressed: onQr,
                    child: const Icon(Icons.qr_code_scanner, size: 23),
                  ),
                ),
                Positioned(
                  left: 28,
                  bottom: 24,
                  child: IconButton(
                    tooltip: 'Refresh contacts',
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh, color: _blue),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _MemberRow extends StatefulWidget {
  const _MemberRow({
    super.key,
    required this.member,
    required this.api,
    required this.onOpen,
  });
  final MemberProfile member;
  final LiveApi api;
  final VoidCallback onOpen;
  @override
  State<_MemberRow> createState() => _MemberRowState();
}

class _MemberRowState extends State<_MemberRow> {
  late final _photo = widget.api.photo(widget.member);
  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _photo,
    builder: (context, snapshot) => ContactRow(
      name: widget.member.profile.name,
      occupation: widget.member.profile.occupation,
      avatar: ProfileAvatar(photo: snapshot.data, size: 65),
      onOpen: widget.onOpen,
    ),
  );
}
