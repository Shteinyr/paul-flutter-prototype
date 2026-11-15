import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'public_preview_api.dart';
import 'public_guest_preview.dart';
import 'invitation_entry_view.dart';
import 'guest_invitation_prompt.dart';
import 'live_api.dart';

/// P16 is intentionally independent of persisted Auth, member controllers,
/// account drafts, registration, Admin and push. It only reads public content
/// and validates an existing invitation before showing the source handoff.
class LimitedPreviewApp extends StatefulWidget {
  const LimitedPreviewApp({
    super.key,
    required this.repository,
    required this.client,
  });
  final PublicPreviewRepository repository;
  final SupabaseClient client;
  @override
  State<LimitedPreviewApp> createState() => _LimitedPreviewAppState();
}

class _LimitedPreviewAppState extends State<LimitedPreviewApp> {
  final _browsing = PublicGuestBrowsingState();
  bool _joining = false, _checking = false, _invalid = false;
  String? get _incoming {
    final fragment = Uri.base.fragment;
    if (!fragment.startsWith('invite=')) return null;
    final value = fragment.substring(7);
    return RegExp(r'^(?:[a-f0-9]{64}|[0-9]{8})$').hasMatch(value)
        ? value
        : null;
  }

  Future<void> _join(BuildContext context, String credential) async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _invalid = false;
    });
    try {
      await LiveApi(widget.client).check(credential);
      if (!context.mounted) return;
      if (!GuestInvitationPrompt.validCode(credential)) {
        // Opaque invitations stay opaque. Never manufacture a manual code or
        // consume an invitation in a preview. The installed app owns signup.
        final uri = Uri(
          scheme: 'app.paul',
          host: 'invite',
          queryParameters: {'invite': credential},
        );
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
      const storeUrl = String.fromEnvironment('PAUL_APP_STORE_URL');
      final store = Uri.tryParse(storeUrl);
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(horizontal: 3, vertical: 24),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: GuestInvitationPrompt(
              invitationCode: credential,
              onCopyCode: () =>
                  unawaited(Clipboard.setData(ClipboardData(text: credential))),
              onGetApp: store?.scheme == 'https' && store!.hasAuthority
                  ? () => unawaited(
                      launchUrl(store, mode: LaunchMode.externalApplication),
                    )
                  : null,
            ),
          ),
        ),
      );
    } on LiveApiException catch (error) {
      if (mounted && error.code == 'invalid_invitation') {
        setState(() => _invalid = true);
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

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
      builder: (context) => _joining
          ? InvitationEntryView(
              pendingCredential: _incoming,
              checking: _checking,
              invalidCode: _invalid,
              onCodeChanged: (_) => setState(() => _invalid = false),
              onBack: () => setState(() => _joining = false),
              onJoin: (value) => unawaited(_join(context, value)),
              onSignIn: (value) => unawaited(_join(context, value)),
            )
          : PublicGuestPreview(
              repository: widget.repository,
              browsingState: _browsing,
              onRequireSignIn: () => setState(() => _joining = true),
              onEditProfile: () => setState(() => _joining = true),
            ),
    ),
  );
  @override
  void dispose() {
    unawaited(widget.client.dispose());
    super.dispose();
  }
}
