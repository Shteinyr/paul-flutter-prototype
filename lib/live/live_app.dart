import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart';
import '../onboarding/onboarding_draft_store.dart';
import '../onboarding/onboarding_flow.dart';
import '../profile/profile_controller.dart';
import '../profile/public_profile_view.dart';
import '../profile/user_profile.dart';
import 'browser_storage.dart';
import 'live_api.dart';
import 'live_qr_view.dart';

const _blue = Color(0xFF14679E);
const _inviteKey = 'paul.live.pending.invitation.v1';
const _draftKey = 'paul.live.pending.profile.v1';
const _finalizeKey = 'paul.live.pending.finalize.v1';

class PaulLiveApp extends StatefulWidget {
  const PaulLiveApp({
    super.key,
    required this.client,
    required this.appUrl,
    required this.googleEnabled,
    required this.appleEnabled,
    this.draftPreferences,
  });
  final SupabaseClient client;
  final Uri appUrl;
  final bool googleEnabled;
  final bool appleEnabled;
  final SharedPreferencesAsync? draftPreferences;
  @override
  State<PaulLiveApp> createState() => _PaulLiveAppState();
}

class _PaulLiveAppState extends State<PaulLiveApp> {
  late final LiveApi _api;
  late final StreamSubscription<AuthState> _auth;
  final _navigator = GlobalKey<NavigatorState>();
  ProfileController? _profile;
  MemberNetwork _network = const MemberNetwork();
  UserProfile? _draft;
  String? _credential;
  String? _identity;
  String? _error;
  bool _loading = true;
  bool _acceptedInvite = false;
  bool _checking = false;
  int _loadGeneration = 0;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
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
    _auth = widget.client.auth.onAuthStateChange.listen(
      (event) {
        if (event.event == AuthChangeEvent.tokenRefreshed) return;
        unawaited(_load());
      },
      onError: (Object _) {
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
    final generation = ++_loadGeneration;
    final identity = widget.client.auth.currentUser?.id;
    if (_identity != identity) {
      _navigator.currentState?.popUntil((route) => route.isFirst);
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
      _identity = identity;
    }
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _loading = true;
      _error = null;
    });
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
          } else if (identity != null &&
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
          } else {
            await _api.check(_credential!);
            _acceptedInvite = true;
          }
        }
      } on LiveApiException catch (error) {
        _error = error.toString();
        _acceptedInvite = false;
      }
      if (!mounted || generation != _loadGeneration) return;
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

  Future<void> _accept(String credential) async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final value = credential.trim();
      await _api.check(value);
      writeSessionValue(_inviteKey, value);
      _credential = value;
      _acceptedInvite = true;
      await _load();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is LiveApiException
              ? error.toString()
              : 'Could not check the code. Please retry.',
        );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<OAuthProvider?> _chooseProvider(BuildContext context) =>
      showDialog<OAuthProvider>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Sign in'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: widget.googleEnabled
                    ? () => Navigator.pop(context, OAuthProvider.google)
                    : null,
                child: const Text('Continue with Google'),
              ),
              TextButton(
                onPressed: widget.appleEnabled
                    ? () => Navigator.pop(context, OAuthProvider.apple)
                    : null,
                child: const Text('Continue with Apple'),
              ),
              if (!widget.googleEnabled && !widget.appleEnabled)
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
            listenable: controller,
            builder: (context, _) => PublicProfileView(
              profile: own ? controller.profile : member.profile,
              avatar: ProfileAvatar(
                photo: own ? controller.profile.photo : photo,
                size: 144,
              ),
              contactCount: own
                  ? _network.contacts.length
                  : member.contactCount,
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
        selectedTab: _tab,
        onSelected: (value) {
          unawaited(_profile!.flush());
          setState(() => _tab = value);
          if (value == 0) unawaited(_load());
        },
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
        onBack: () => setState(() => _acceptedInvite = false),
        onComplete: (draft) => _complete(context, draft),
      );
    }
    return _JoinView(
      error: _error,
      checking: _checking,
      onAccept: _accept,
      onRetry:
          _error != null &&
              (_credential != null || widget.client.auth.currentUser != null)
          ? _load
          : null,
      onSignIn: () async {
        removeSessionValue(_finalizeKey);
        final provider = await _chooseProvider(context);
        if (provider == null || !mounted) return;
        try {
          await _signIn(provider);
        } catch (_) {
          if (mounted) {
            setState(
              () => _error = 'Could not open sign-in. Please try again.',
            );
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
  });
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
          const Text(
            'Enter your invitation code',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w300),
          ),
          const SizedBox(height: 24),
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
                : () => widget.onAccept(_code.text),
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
          const SizedBox(height: 40),
          TextButton(
            onPressed: widget.onSignIn,
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
    required this.onQr,
    required this.onDismissInvite,
    required this.selectedTab,
    required this.onSelected,
    this.error,
  });
  final ProfileController profile;
  final MemberNetwork network;
  final LiveApi api;
  final Future<void> Function() onRefresh;
  final Future<void> Function(MemberProfile) onProfile;
  final VoidCallback onLogout;
  final VoidCallback onQr;
  final VoidCallback onDismissInvite;
  final String? error;
  final int selectedTab;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => _EntryFrame(
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 70, 28, 0),
          child: ProfileNavigation(
            selected: selectedTab,
            onSelected: onSelected,
            enabledTabs: const {0, 3},
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
        if (selectedTab == 3)
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
                        child: TextButton(
                          onPressed: onLogout,
                          child: const Text('Sign out'),
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
