import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../photo_picker.dart';
import '../profile/profile_controller.dart';
import '../profile/user_profile.dart';
import 'onboarding_draft_store.dart';
import 'onboarding_skills_step.dart';

/// The registration host completes authentication, upload and membership before
/// onComplete returns. A local-only host uses onContinueToRegistration instead.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({
    super.key,
    this.onComplete,
    this.onContinueToRegistration,
    this.initialDraft,
    this.onBack,
    this.pickPhoto,
    this.preferences,
    this.maxOfferingSkills = 5,
  }) : assert((onComplete == null) != (onContinueToRegistration == null));

  final Future<void> Function(UserProfile draft)? onComplete;

  /// Local-only handoff. Saves the draft without claiming registration success
  /// or clearing it; the host must still check an invitation and authenticate.
  final ValueChanged<UserProfile>? onContinueToRegistration;

  /// Recovery seed used when no valid local onboarding draft is available.
  final UserProfile? initialDraft;
  final VoidCallback? onBack;
  final PickProfilePhoto? pickPhoto;
  final SharedPreferencesAsync? preferences;
  final int maxOfferingSkills;

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

/// A safe, user-facing error supplied by the registration host.
class OnboardingSubmissionException implements Exception {
  const OnboardingSubmissionException(this.message);
  final String message;
}

class _OnboardingFlowState extends State<OnboardingFlow>
    with WidgetsBindingObserver {
  late final OnboardingDraftStore _store;
  late final ProfileController _controller;
  final _name = TextEditingController();
  final _occupation = TextEditingController();
  final _summary = TextEditingController();
  final _occupationFocus = FocusNode();
  final _summaryFocus = FocusNode();
  Timer? _inputSave;
  bool _working = false;
  bool _picking = false;
  bool _validate = false;
  bool _serverCompleted = false;
  String? _draftError;
  String? _submitError;
  String? _photoError;

  int get _step => _store.step;
  UserProfile get _profile => _controller.profile;
  bool get _busy => _working || _picking || _serverCompleted;

  @override
  void initState() {
    super.initState();
    _store = OnboardingDraftStore(
      preferences: widget.preferences,
      initialDraft: widget.initialDraft,
    );
    _controller = ProfileController(
      _store,
      offeringLimit: widget.maxOfferingSkills,
    )..addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  Future<void> _load() async {
    await _controller.load();
    if (!mounted || !_controller.loaded) return;
    if (widget.initialDraft != null) await _saveDraft();
  }

  void _changed() {
    if (!mounted) return;
    _sync(_name, _profile.name);
    _sync(_occupation, _profile.occupation);
    _sync(_summary, _profile.summary);
    setState(() {});
  }

  void _sync(TextEditingController controller, String value) {
    if (controller.text != value) {
      controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    }
  }

  void _inputChanged(String value, {required bool searching}) {
    if (searching) {
      _store.searchingInput = value;
    } else {
      _store.offeredInput = value;
    }
    _inputSave?.cancel();
    _inputSave = Timer(const Duration(milliseconds: 250), () {
      _inputSave = null;
      unawaited(_saveDraft());
    });
  }

  Future<bool> _saveDraft() async {
    _inputSave?.cancel();
    _inputSave = null;
    await _controller.flush();
    if (_controller.error != null) return false;
    try {
      await _store.write(_profile);
      if (mounted) setState(() => _draftError = null);
      return true;
    } catch (_) {
      if (mounted) {
        setState(() => _draftError = 'Could not save your draft. Tap Retry.');
      }
      return false;
    }
  }

  Future<void> _move(int direction) async {
    if (_busy || !_controller.loaded) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (direction > 0 &&
        _step == 0 &&
        (_profile.skills.isEmpty ||
            _profile.skills.length > widget.maxOfferingSkills)) {
      setState(() => _validate = true);
      return;
    }
    setState(() => _working = true);
    if (!await _saveDraft() || !mounted) {
      if (mounted) setState(() => _working = false);
      return;
    }
    if (_step == 0 && direction < 0) {
      setState(() => _working = false);
      widget.onBack?.call();
      return;
    }
    final previous = _step;
    _store.step += direction;
    try {
      await _store.write(_profile);
      if (mounted) {
        setState(() {
          _working = false;
          _validate = false;
          _submitError = null;
        });
      }
    } catch (_) {
      _store.step = previous;
      if (mounted) {
        setState(() {
          _working = false;
          _draftError = 'Could not save your draft. Tap Retry.';
        });
      }
    }
  }

  Future<void> _choosePhoto() async {
    if (_busy) return;
    setState(() {
      _picking = true;
      _photoError = null;
    });
    try {
      final photo = await (widget.pickPhoto ?? pickProfilePhoto)();
      if (!mounted || photo == null) return;
      _controller.updatePhoto(photo);
      await _saveDraft();
    } on PhotoSelectionException catch (error) {
      if (mounted) setState(() => _photoError = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _photoError = 'Could not select a photo. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  bool get _validProfile =>
      _profile.photo != null &&
      _profile.photo!.isNotEmpty &&
      _profile.name.trim().isNotEmpty &&
      _profile.summary.trim().isNotEmpty &&
      _profile.photo!.lengthInBytes <= 3 * 1024 * 1024 &&
      _profile.name.characters.length <= 120 &&
      _profile.occupation.characters.length <= 120 &&
      _profile.summary.characters.length <= 500 &&
      _profile.skills.isNotEmpty &&
      _profile.skills.length <= widget.maxOfferingSkills &&
      _profile.searchingSkills.length <= 100;

  Future<void> _complete() async {
    if (_busy || !_controller.loaded) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _validate = true;
      _submitError = null;
    });
    if (!_validProfile) {
      if (_profile.photo != null &&
          (_profile.photo!.isEmpty ||
              _profile.photo!.lengthInBytes > 3 * 1024 * 1024)) {
        setState(() => _photoError = 'Choose an image smaller than 3 MB.');
      }
      if (_profile.skills.length > widget.maxOfferingSkills ||
          _profile.searchingSkills.length > 100) {
        setState(
          () =>
              _submitError = 'Skill limit reached. Remove a skill to continue.',
        );
      }
      if (_profile.skills.isEmpty ||
          _profile.skills.length > widget.maxOfferingSkills) {
        await _move(-1);
        if (mounted) await _move(-1);
        if (mounted) setState(() => _validate = true);
      }
      return;
    }
    setState(() => _working = true);
    if (!await _saveDraft() || !mounted) {
      if (mounted) setState(() => _working = false);
      return;
    }
    try {
      if (widget.onContinueToRegistration != null) {
        widget.onContinueToRegistration!(_profile);
        return;
      }
      await widget.onComplete!(_profile);
      _serverCompleted = true;
      await _store.clear();
    } on OnboardingSubmissionException catch (error) {
      if (mounted) setState(() => _submitError = error.message);
    } catch (_) {
      if (mounted) {
        setState(() {
          _submitError = _serverCompleted
              ? 'Registration succeeded. Could not clear the local draft.'
              : 'Could not complete registration. Your draft is saved. Please try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _retryDraftCleanup() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await _store.clear();
      if (mounted) setState(() => _submitError = null);
    } catch (_) {
      if (mounted) {
        setState(
          () => _submitError = 'Could not clear the local draft. Tap Retry.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed &&
        _controller.loaded &&
        !_serverCompleted) {
      unawaited(_saveDraft());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_serverCompleted) {
      return Scaffold(
        backgroundColor: const Color(0xFFF4F4F4),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Registration complete.'),
                if (_submitError != null) ...[
                  const SizedBox(height: 16),
                  Text(_submitError!, textAlign: TextAlign.center),
                  TextButton(
                    key: const Key('onboarding-retry-cleanup'),
                    onPressed: _working ? null : _retryDraftCleanup,
                    child: const Text('Retry'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }
    if (!_controller.loaded || _controller.loadFailed) {
      return Scaffold(
        backgroundColor: const Color(0xFFF4F4F4),
        body: Center(
          child: _controller.loadFailed
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Could not load your registration draft.'),
                    TextButton(onPressed: _load, child: const Text('Retry')),
                  ],
                )
              : const CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final title = ['Getting Started', 'Searching Skills', 'About You'][_step];
    final searching = _step == 1;
    final description = [
      'Add your skills to increase visibility in our community  (1/3)',
      'List skills you or your friends might be searching for  (2/3)',
      'Let community reach you, introduce yourself  (3/3)',
    ][_step];
    final saveError = _draftError ?? _controller.error;
    return PopScope(
      canPop: _step == 0 && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) unawaited(_move(-1));
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF4F4F4),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 402),
            child: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 60, 20, 0),
                    child: Row(
                      children: [
                        IconButton(
                          key: const Key('onboarding-back'),
                          tooltip: 'Back',
                          onPressed:
                              _busy || (_step == 0 && widget.onBack == null)
                              ? null
                              : () => _move(-1),
                          icon: const Icon(Icons.arrow_back, size: 22),
                        ),
                        Expanded(
                          child: Text(
                            title,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 16,
                              height: 20 / 16,
                              fontWeight: FontWeight.w500,
                              letterSpacing: .5,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 48,
                          child: IconButton(
                            key: Key(
                              _step == 2
                                  ? 'onboarding-complete'
                                  : 'onboarding-next',
                            ),
                            tooltip: _step == 2
                                ? 'Continue to sign in'
                                : 'Next',
                            onPressed: _busy
                                ? null
                                : _step == 2
                                ? _complete
                                : () => _move(1),
                            icon: _working && _step == 2
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.arrow_forward, size: 22),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (saveError != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              saveError,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          TextButton(
                            key: const Key('onboarding-retry-save'),
                            onPressed: _busy ? null : _saveDraft,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: SingleChildScrollView(
                      key: ValueKey('onboarding-scroll-$_step'),
                      padding: const EdgeInsets.fromLTRB(37.5, 15, 37.5, 40),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: SizedBox(
                              width: 236,
                              child: Text(
                                description,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 12,
                                  height: 22 / 12,
                                  fontWeight: FontWeight.w300,
                                  letterSpacing: .5,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 50),
                          if (_step < 2)
                            OnboardingSkillsStep(
                              key: ValueKey('onboarding-skills-$_step'),
                              controller: _controller,
                              searching: searching,
                              maxSkills: searching
                                  ? 100
                                  : widget.maxOfferingSkills,
                              input: searching
                                  ? _store.searchingInput
                                  : _store.offeredInput,
                              onInputChanged: (value) =>
                                  _inputChanged(value, searching: searching),
                              onSaved: () => unawaited(_saveDraft()),
                              validate: _validate,
                              enabled: !_busy,
                            )
                          else ...[
                            _aboutYou(),
                            const SizedBox(height: 30),
                            if (_submitError != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(
                                  _submitError!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFFFF645C),
                                  ),
                                ),
                              ),
                          ],
                        ],
                      ),
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

  Widget _aboutYou() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Center(
        child: SizedBox(
          width: 176,
          height: 160,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: 8,
                left: 16,
                child: Semantics(
                  label: _profile.photo == null
                      ? 'Add profile photo'
                      : 'Change profile photo',
                  button: true,
                  child: InkWell(
                    key: const Key('onboarding-photo'),
                    onTap: _busy ? null : _choosePhoto,
                    borderRadius: BorderRadius.circular(72),
                    child: ClipOval(
                      child: SizedBox(
                        width: 144,
                        height: 144,
                        child: _profile.photo == null
                            ? ColoredBox(
                                color: const Color(0xFFE9E9E9),
                                child: Center(
                                  child: _picking
                                      ? const CircularProgressIndicator(
                                          strokeWidth: 2,
                                        )
                                      : SvgPicture.asset(
                                          'assets/icons/camera.svg',
                                          width: 22,
                                          height: 20,
                                        ),
                                ),
                              )
                            : Image.memory(
                                _profile.photo!,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                                errorBuilder: (_, _, _) =>
                                    const Icon(Icons.broken_image_outlined),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              if (_profile.photo != null)
                Positioned(
                  right: 0,
                  top: -4,
                  child: IconButton(
                    key: const Key('onboarding-remove-photo'),
                    tooltip: 'Remove photo',
                    onPressed: _busy
                        ? null
                        : () {
                            setState(() => _photoError = null);
                            _controller.removePhoto();
                            unawaited(_saveDraft());
                          },
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ),
            ],
          ),
        ),
      ),
      if (_photoError != null || (_validate && _profile.photo == null))
        Text(
          _photoError ?? 'Required',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: Color(0xFFFF645C)),
        ),
      const SizedBox(height: 36),
      _OnboardingField(
        fieldKey: const Key('onboarding-name'),
        controller: _name,
        hint: 'What’s your name?',
        maxLength: 120,
        enabled: !_busy,
        required: _validate,
        onChanged: _controller.updateName,
        onSubmitted: (_) => _occupationFocus.requestFocus(),
        autofillHints: const [AutofillHints.name],
      ),
      const SizedBox(height: 23),
      _OnboardingField(
        fieldKey: const Key('onboarding-occupation'),
        controller: _occupation,
        focusNode: _occupationFocus,
        hint: 'What’s occupation?',
        maxLength: 120,
        enabled: !_busy,
        onChanged: _controller.updateOccupation,
        onSubmitted: (_) => _summaryFocus.requestFocus(),
      ),
      const SizedBox(height: 43),
      _OnboardingField(
        fieldKey: const Key('onboarding-summary'),
        controller: _summary,
        focusNode: _summaryFocus,
        hint: 'Short summary',
        maxLength: 500,
        maxLines: 6,
        enabled: !_busy,
        required: _validate,
        onChanged: _controller.updateSummary,
      ),
    ],
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _inputSave?.cancel();
    if (_controller.loaded && !_serverCompleted) unawaited(_saveDraft());
    _controller.removeListener(_changed);
    _controller.dispose();
    _name.dispose();
    _occupation.dispose();
    _summary.dispose();
    _occupationFocus.dispose();
    _summaryFocus.dispose();
    super.dispose();
  }
}

class _OnboardingField extends StatelessWidget {
  const _OnboardingField({
    required this.fieldKey,
    required this.controller,
    required this.hint,
    required this.maxLength,
    required this.enabled,
    required this.onChanged,
    this.required = false,
    this.maxLines = 1,
    this.focusNode,
    this.onSubmitted,
    this.autofillHints,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String hint;
  final int maxLength;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final bool required;
  final int maxLines;
  final FocusNode? focusNode;
  final ValueChanged<String>? onSubmitted;
  final Iterable<String>? autofillHints;

  String? get _error {
    if (required && controller.text.trim().isEmpty) return 'Required';
    if (controller.text.characters.length > maxLength) {
      return 'Use $maxLength characters or fewer.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        key: fieldKey,
        controller: controller,
        focusNode: focusNode,
        enabled: enabled,
        textAlign: TextAlign.center,
        textCapitalization: maxLines == 1
            ? TextCapitalization.words
            : TextCapitalization.sentences,
        textInputAction: maxLines == 1
            ? TextInputAction.next
            : TextInputAction.newline,
        keyboardType: maxLines == 1
            ? TextInputType.text
            : TextInputType.multiline,
        maxLength: maxLength,
        maxLines: maxLines,
        minLines: 1,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        autofillHints: autofillHints,
        style: TextStyle(
          fontSize: maxLines == 1 ? 15 : 12,
          height: maxLines == 1 ? 22 / 15 : 25 / 12,
          letterSpacing: .5,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w300,
            color: Color(0xFF14679E),
          ),
          counterText: '',
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
      SvgPicture.asset('assets/icons/field-separator.svg'),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Color(0xFFFF645C)),
          ),
        ),
    ],
  );
}
