import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _blue = Color(0xFF14679E);
const _red = Color(0xFFFF645C);

/// P06 source 61854:3985; focused/invalid 4209,4254 and 61855:4290.
/// Source phone artwork is excluded: its real screen is 402×874 at (68,85).
/// Callbacks own invitation validation/routing; this view never starts OAuth.
class InvitationEntryView extends StatefulWidget {
  const InvitationEntryView({
    super.key,
    required this.onJoin,
    required this.onSignIn,
    this.initialCode = '',
    this.pendingCredential,
    this.checking = false,
    this.invalidCode = false,
    this.errorText,
    this.onRetry,
    this.onCodeChanged,
    this.onTermsOfUse,
    this.onPrivacyPolicy,
    this.onBack,
    this.appName = 'App Name',
    this.slogan =
        'Your CV looks fine... People just hiring their friends and relatives ',
  });
  final ValueChanged<String> onJoin, onSignIn;
  final String initialCode;

  /// An incoming QR credential is opaque; manually entered text takes precedence.
  final String? pendingCredential;
  final bool checking, invalidCode;
  final String? errorText;
  final VoidCallback? onRetry;
  final ValueChanged<String>? onCodeChanged;
  final VoidCallback? onTermsOfUse, onPrivacyPolicy, onBack;
  final String appName, slogan;
  @override
  State<InvitationEntryView> createState() => _InvitationEntryViewState();
}

class _InvitationEntryViewState extends State<InvitationEntryView> {
  late final TextEditingController _code;
  final _focus = FocusNode();
  late final TapGestureRecognizer _terms, _privacy;
  @override
  void initState() {
    super.initState();
    _code = TextEditingController(
      text: RegExp(r'^\d{0,8}$').hasMatch(widget.initialCode)
          ? widget.initialCode
          : '',
    );
    _focus.addListener(_changed);
    _terms = TapGestureRecognizer();
    _privacy = TapGestureRecognizer();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  String get _credential => _code.text.trim().isNotEmpty
      ? _code.text.trim()
      : widget.pendingCredential ?? '';
  void _join() {
    if (!widget.checking) {
      _focus.unfocus();
      if (widget.onRetry != null) {
        widget.onRetry!();
      } else {
        widget.onJoin(_credential);
      }
    }
  }

  void _signIn() {
    if (!widget.checking) {
      _focus.unfocus();
      widget.onSignIn(_credential);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_changed);
    _focus.dispose();
    _code.dispose();
    _terms.dispose();
    _privacy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _terms.onTap = widget.onTermsOfUse;
    _privacy.onTap = widget.onPrivacyPolicy;
    final compact =
        _focus.hasFocus || MediaQuery.viewInsetsOf(context).bottom > 0;
    final fieldTop = compact ? 329.0 : 584.0;
    final joinTop = compact ? 431.0 : 699.0;
    final termsTop = compact ? 518.0 : 764.0;
    return Scaffold(
      backgroundColor: const Color(0xFFF4F4F4),
      body: Stack(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final width = math.min(402.0, constraints.maxWidth);
              final left = (width - 402) / 2;
              return Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: width,
                  child: SingleChildScrollView(
                    key: const Key('invitation-entry-scroll'),
                    child: SizedBox(
                      height: compact ? 613 : 874,
                      child: Stack(
                        children: [
                          Positioned(
                            left: left + (compact ? 72 : 74),
                            top: compact ? 183 : 358,
                            width: 257,
                            height: 36,
                            child: Text(
                              widget.appName,
                              key: const Key('invitation-app-name'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontFamily: 'NotoSans',
                                fontSize: 20,
                                height: 25 / 20,
                                color: Colors.black,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ),
                          if (!compact)
                            Positioned(
                              left: left + 60,
                              top: 415,
                              width: 301,
                              height: 60,
                              child: Text(
                                widget.slogan,
                                key: const Key('invitation-slogan'),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontFamily: 'NotoSans',
                                  fontSize: 13,
                                  height: 25 / 13,
                                  color: Colors.black,
                                  fontWeight: FontWeight.w300,
                                ),
                              ),
                            ),
                          Positioned(
                            key: const Key('invitation-code-position'),
                            left: left + 60,
                            top: fieldTop,
                            width: 283,
                            height: 55,
                            child: TextField(
                              key: const Key('invite-code-input'),
                              controller: _code,
                              focusNode: _focus,
                              enabled: !widget.checking,
                              keyboardType: TextInputType.number,
                              textInputAction: TextInputAction.done,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(8),
                              ],
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontFamily: 'NotoSans',
                                fontSize: 24,
                                height: 22 / 24,
                                color: Colors.black,
                              ),
                              decoration: const InputDecoration(
                                hintText: 'Entire invite code ',
                                hintStyle: TextStyle(
                                  fontFamily: 'NotoSans',
                                  fontSize: 15,
                                  height: 22 / 15,
                                  fontWeight: FontWeight.w300,
                                  color: Colors.black,
                                ),
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                disabledBorder: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.only(top: 12),
                              ),
                              onChanged: (value) {
                                widget.onCodeChanged?.call(value);
                                _changed();
                              },
                              onSubmitted: (_) => _join(),
                            ),
                          ),
                          Positioned(
                            left: left + 76,
                            top: compact ? 386 : 639,
                            width: 250,
                            height: 1,
                            child: ColoredBox(
                              key: const Key('invitation-code-underline'),
                              color: widget.invalidCode
                                  ? _red
                                  : _code.text.isEmpty
                                  ? _blue.withValues(alpha: 0.5)
                                  : _blue,
                            ),
                          ),
                          if (widget.invalidCode || widget.errorText != null)
                            Positioned(
                              left: left + (widget.invalidCode ? 121 : 37.5),
                              top: compact ? 397 : 649,
                              width: widget.invalidCode ? 160 : 327,
                              height: widget.invalidCode ? 20 : 44,
                              child: Text(
                                widget.invalidCode
                                    ? 'Invalid code'
                                    : widget.errorText!,
                                key: const Key('invitation-invalid-code'),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontFamily: 'NotoSans',
                                  fontSize: 12,
                                  height: 20 / 12,
                                  color: _red,
                                  fontWeight: FontWeight.w300,
                                ),
                              ),
                            ),
                          Positioned(
                            left: left + 120,
                            top: joinTop,
                            width: 162,
                            height: 42,
                            child: TextButton(
                              key: const Key('invitation-join'),
                              onPressed: widget.checking ? null : _join,
                              style: TextButton.styleFrom(
                                backgroundColor: _blue,
                                disabledBackgroundColor: _blue,
                                foregroundColor: const Color(0xFFF4F4F4),
                                disabledForegroundColor: const Color(
                                  0xFFF4F4F4,
                                ),
                                padding: EdgeInsets.zero,
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(30),
                                ),
                                textStyle: const TextStyle(
                                  fontFamily: 'NotoSans',
                                  fontSize: 15,
                                  height: 20 / 15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              child: Text(
                                widget.onRetry == null ? 'Join' : 'Retry',
                              ),
                            ),
                          ),
                          // Explicitly approved exception, immediately below the source Join button.
                          Positioned(
                            left: left + 67,
                            top: joinTop + 45,
                            width: 269,
                            height: 20,
                            child: TextButton(
                              key: const Key('invitation-existing-member'),
                              onPressed: widget.checking ? null : _signIn,
                              style: TextButton.styleFrom(
                                foregroundColor: _blue,
                                padding: EdgeInsets.zero,
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                textStyle: const TextStyle(
                                  fontFamily: 'NotoSans',
                                  fontSize: 12,
                                  height: 18 / 12,
                                  fontWeight: FontWeight.w300,
                                ),
                              ),
                              child: const Text('Already a member? Sign in'),
                            ),
                          ),
                          Positioned(
                            left: left + 67,
                            top: termsTop,
                            width: 269,
                            height: 59,
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  const TextSpan(
                                    text: 'By continuing, you agree to the ',
                                  ),
                                  TextSpan(
                                    text: 'Terms of Use',
                                    recognizer: widget.onTermsOfUse == null
                                        ? null
                                        : _terms,
                                  ),
                                  const TextSpan(text: ' and '),
                                  TextSpan(
                                    text: 'Privacy Policy',
                                    recognizer: widget.onPrivacyPolicy == null
                                        ? null
                                        : _privacy,
                                  ),
                                  const TextSpan(text: '.'),
                                ],
                              ),
                              key: const Key('invitation-terms'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontFamily: 'NotoSans',
                                fontSize: 12,
                                height: 24 / 12,
                                fontWeight: FontWeight.w300,
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          if (widget.onBack != null)
            Positioned(
              left:
                  math.max(0, (MediaQuery.sizeOf(context).width - 402) / 2) +
                  28,
              top: MediaQuery.paddingOf(context).top + 12,
              child: IconButton(
                key: const Key('join-back'),
                onPressed: widget.onBack,
                icon: const Icon(
                  Icons.arrow_back_ios_new,
                  size: 18,
                  color: _blue,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
