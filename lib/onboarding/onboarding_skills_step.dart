import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../profile/profile_controller.dart';
import '../skills/skill_suggestions.dart';

class OnboardingSkillsStep extends StatefulWidget {
  const OnboardingSkillsStep({
    super.key,
    required this.controller,
    required this.input,
    required this.onInputChanged,
    required this.onSaved,
    this.validate = false,
    this.enabled = true,
    this.maxSkills = 100,
    this.searching = false,
  });

  final ProfileController controller;
  final String input;
  final ValueChanged<String> onInputChanged;
  final VoidCallback onSaved;
  final bool validate;
  final bool enabled;
  final int maxSkills;
  final bool searching;

  @override
  State<OnboardingSkillsStep> createState() => _OnboardingSkillsStepState();
}

class _OnboardingSkillsStepState extends State<OnboardingSkillsStep> {
  late final TextEditingController _input;
  final _focus = FocusNode();
  String? _error;

  List<String> get _skills => widget.searching
      ? widget.controller.profile.searchingSkills
      : widget.controller.profile.skills;

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: widget.input);
  }

  void _add() {
    if (!widget.enabled) return;
    if (_input.text.trim().isEmpty) {
      setState(() => _error = widget.searching ? null : 'Required');
      _focus.requestFocus();
      return;
    }
    if (_input.text.characters.length > 64) {
      setState(() => _error = 'Use 64 characters or fewer.');
      return;
    }
    if (_skills.length >= widget.maxSkills) {
      setState(() => _error = 'Skill limit reached');
      return;
    }
    if (!widget.controller.addSkill(_input.text, searching: widget.searching)) {
      setState(() => _error = 'Already added');
      return;
    }
    _input.clear();
    widget.onInputChanged('');
    widget.onSaved();
    setState(() => _error = null);
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final error =
        _error ??
        (widget.validate && _skills.length > widget.maxSkills
            ? 'Choose up to ${widget.maxSkills} offered skills before continuing.'
            : null) ??
        (widget.validate && !widget.searching && _skills.isEmpty
            ? 'Required'
            : null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 54,
          child: Stack(
            children: [
              TextField(
                key: const Key('onboarding-skill-input'),
                controller: _input,
                focusNode: _focus,
                enabled: widget.enabled,
                textAlign: TextAlign.center,
                textInputAction: TextInputAction.done,
                textCapitalization: TextCapitalization.words,
                maxLength: 64,
                onChanged: (value) {
                  widget.onInputChanged(value);
                  setState(() => _error = null);
                },
                onSubmitted: (_) => _add(),
                style: const TextStyle(
                  fontSize: 15,
                  height: 22 / 15,
                  letterSpacing: .5,
                ),
                decoration: const InputDecoration(
                  hintText: 'Example: Marketing',
                  hintStyle: TextStyle(
                    fontWeight: FontWeight.w100,
                    color: Color(0x33000000),
                  ),
                  counterText: '',
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.fromLTRB(30, 13, 40, 18),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SvgPicture.asset('assets/icons/field-separator.svg'),
              ),
              Positioned(
                right: -10,
                top: 1,
                child: IconButton(
                  key: const Key('onboarding-add-skill'),
                  tooltip: 'Add skill',
                  onPressed: widget.enabled ? _add : null,
                  icon: SvgPicture.asset(
                    'assets/icons/add-skill.svg',
                    width: 12.5,
                    height: 12.5,
                  ),
                ),
              ),
            ],
          ),
        ),
        SkillSuggestions(
          controller: _input,
          focusNode: _focus,
          selected: _skills,
          enabled: widget.enabled,
          onSelected: (value) {
            _input.text = value;
            widget.onInputChanged(value);
            _add();
          },
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFFFF645C)),
            ),
          ),
        if (_skills.isNotEmpty) ...[
          const SizedBox(height: 21),
          Wrap(
            spacing: 8,
            runSpacing: 9,
            children: [
              for (final skill in _skills)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        skill,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 20 / 12,
                          fontWeight: FontWeight.w300,
                          letterSpacing: .5,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove $skill',
                      onPressed: widget.enabled
                          ? () {
                              widget.controller.removeSkill(
                                skill,
                                searching: widget.searching,
                              );
                              widget.onSaved();
                              setState(() => _error = null);
                            }
                          : null,
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      padding: EdgeInsets.zero,
                      icon: Transform.rotate(
                        angle: -3 * math.pi / 4,
                        child: SvgPicture.asset(
                          'assets/icons/remove-photo.svg',
                          width: 12.5,
                          height: 12.5,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ],
    );
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }
}
