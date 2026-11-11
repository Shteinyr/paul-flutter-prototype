import 'dart:async';

import 'package:flutter/material.dart';

import 'skill_catalogue.dart';

class SkillSuggestions extends StatefulWidget {
  const SkillSuggestions({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.selected,
    required this.onSelected,
    this.enabled = true,
    this.catalogue,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final List<String> selected;
  final ValueChanged<String> onSelected;
  final bool enabled;
  final SkillCatalogue? catalogue;

  @override
  State<SkillSuggestions> createState() => _SkillSuggestionsState();
}

class _SkillSuggestionsState extends State<SkillSuggestions> {
  Timer? _timer;
  int _revision = 0;
  List<SkillSuggestion> _items = const [];
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.focusNode.addListener(_changed);
  }

  void _changed() {
    _timer?.cancel();
    final revision = ++_revision;
    setState(() {
      _items = const [];
      _failed = false;
    });
    if (!widget.enabled ||
        !widget.focusNode.hasFocus ||
        widget.controller.text.trim().isEmpty) {
      return;
    }
    _timer = Timer(
      const Duration(milliseconds: 150),
      () => unawaited(_load(revision)),
    );
  }

  Future<void> _load(int revision) async {
    try {
      final items = await (widget.catalogue ?? SkillCatalogue.shared).suggest(
        widget.controller.text,
      );
      if (!mounted || revision != _revision || !widget.enabled) return;
      final existing = widget.selected.map(skillKey).toSet();
      setState(() {
        _items = items
            .where((item) => !existing.contains(item.key))
            .take(4)
            .toList();
      });
    } catch (_) {
      if (mounted && revision == _revision) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    if (_failed) {
      return TextButton(
        onPressed: _changed,
        child: const Text('Could not load suggestions. Retry'),
      );
    }
    if (_items.isEmpty) return const SizedBox.shrink();
    return TextFieldTapRegion(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in _items)
            TextButton(
              key: ValueKey('catalogue-${item.key}'),
              style: TextButton.styleFrom(
                alignment: Alignment.centerLeft,
                foregroundColor: const Color(0xFF14679E),
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w300,
                ),
                minimumSize: const Size(0, 40),
              ),
              onPressed: () => widget.onSelected(item.label),
              child: Text(
                item.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          TextButton(
            onPressed: () => showSkillCatalogueAttribution(context),
            child: const Text(
              'Skill catalogue source',
              style: TextStyle(fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _revision++;
    _timer?.cancel();
    widget.controller.removeListener(_changed);
    widget.focusNode.removeListener(_changed);
    super.dispose();
  }
}

Future<void> showSkillCatalogueAttribution(
  BuildContext context,
) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('Skill catalogue'),
    content: const Text(
      'This service uses the ESCO classification of the European Commission.\n\n'
      'English preferred labels, ESCO v1.2.1.\n'
      'Reuse under Commission Decision 2011/833/EU.\n'
      'https://esco.ec.europa.eu/en/use-esco\n\n'
      'You can also enter your own skill name.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  ),
);
