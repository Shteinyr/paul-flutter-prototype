import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'public_preview_api.dart';
import 'public_guest_preview.dart';
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
  bool _showingHandoff = false;
  String? get _incoming {
    final fragment = Uri.base.fragment;
    if (!fragment.startsWith('invite=')) return null;
    final value = fragment.substring(7);
    return RegExp(r'^(?:[a-f0-9]{64}|[0-9]{8})$').hasMatch(value)
        ? value
        : null;
  }

  Future<void> _openApp(Uri destination) async {
    try {
      await launchUrl(destination, mode: LaunchMode.externalApplication);
    } catch (_) {
      // A missing app/OS handler must leave the original preview and handoff
      // available. It is not a completed signup or a successful store launch.
    }
  }

  Future<void> _handoff(BuildContext context) async {
    if (_showingHandoff) return;
    _showingHandoff = true;
    String? code;
    const storeUrl = String.fromEnvironment('PAUL_APP_STORE_URL');
    final store = Uri.tryParse(storeUrl);
    Uri? destination = store?.scheme == 'https' && store!.hasAuthority
        ? store
        : null;
    try {
      final credential = _incoming;
      if (credential != null) {
        try {
          await LiveApi(widget.client).check(credential);
          if (GuestInvitationPrompt.validCode(credential)) {
            code = credential;
          } else {
            // Only a validated, existing opaque invitation can open the app.
            // It is never exposed as a manual code or consumed by the preview.
            destination = Uri(
              scheme: 'app.paul',
              host: 'invite',
              queryParameters: {'invite': credential},
            );
          }
        } catch (_) {
          // Expired/unavailable invitations do not block public browsing or
          // become a fabricated code. Store delivery remains independent.
        }
      }
      if (!context.mounted) return;
      final target = destination;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(horizontal: 3, vertical: 24),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: GuestAppPrompt(
              invitationCode: code,
              onCopyCode: code == null
                  ? null
                  : () => unawaited(
                      Clipboard.setData(ClipboardData(text: code!)),
                    ),
              onGetApp: target != null
                  ? () => unawaited(_openApp(target))
                  : null,
            ),
          ),
        ),
      );
    } finally {
      _showingHandoff = false;
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
      builder: (context) => PublicGuestPreview(
        repository: widget.repository,
        browsingState: _browsing,
        limited: true,
        onRequireSignIn: () => unawaited(_handoff(context)),
        onEditProfile: () => unawaited(_handoff(context)),
      ),
    ),
  );
  @override
  void dispose() {
    unawaited(widget.client.dispose());
    super.dispose();
  }
}
