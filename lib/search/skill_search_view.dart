import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'skill_search_api.dart';
import 'skill_search_controller.dart';

const _blue = Color(0xFF14679E);

class SkillSearchView extends StatefulWidget {
  const SkillSearchView({
    super.key,
    required this.controller,
    required this.contacts,
    required this.onOpen,
    required this.avatarFor,
    this.onAskCommunity,
  });
  final SkillSearchController controller;
  final Widget contacts;
  final Future<void> Function(SkillSearchHit) onOpen;
  final Widget Function(SkillSearchHit) avatarFor;
  final ValueChanged<String>? onAskCommunity;
  @override
  State<SkillSearchView> createState() => _SkillSearchViewState();
}

class _SkillSearchViewState extends State<SkillSearchView> {
  final _field = TextEditingController();
  final _focus = FocusNode();
  String? _opening;

  @override
  void initState() {
    super.initState();
    _syncField();
    _focus.addListener(_focusChanged);
    widget.controller.addListener(_syncField);
  }

  @override
  void didUpdateWidget(SkillSearchView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncField);
      widget.controller.addListener(_syncField);
      _syncField();
    }
  }

  void _focusChanged() {
    if (mounted) setState(() {});
  }

  String _label(SkillSearchKind kind) =>
      kind == SkillSearchKind.offering ? 'Offer' : kind.label;

  void _submit() {
    _focus.unfocus();
    unawaited(widget.controller.submit());
  }

  void _syncField() {
    final query = widget.controller.query;
    if (_field.text != query) {
      _field.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    }
  }

  Future<void> _open(SkillSearchHit hit) async {
    if (_opening != null) return;
    setState(() => _opening = hit.id);
    try {
      await widget.onOpen(hit);
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final search = widget.controller;
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(37.5, 24, 37.5, 0),
            child: TextField(
              key: const Key('skill-search-field'),
              controller: _field,
              focusNode: _focus,
              onChanged: search.setQuery,
              onSubmitted: (_) => _submit(),
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w300),
              decoration: InputDecoration(
                hintText: 'Search skills, example “Marketing”',
                hintStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w300,
                ),
                prefixIcon: const Icon(
                  Icons.search,
                  size: 25,
                  color: Colors.black,
                ),
                prefixIconConstraints: const BoxConstraints(minWidth: 40),
                suffixIcon: search.idle
                    ? null
                    : IconButton(
                        tooltip: 'Clear skill search',
                        onPressed: () => search.setQuery(''),
                        icon: const Icon(Icons.close, size: 21),
                      ),
                enabledBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFFCDDEE8)),
                ),
                focusedBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: _blue),
                ),
              ),
            ),
          ),
          if (search.selected != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(37.5, 6, 30, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (final kind in SkillSearchKind.values)
                    Semantics(
                      selected: search.kind == kind,
                      child: TextButton(
                        key: Key('skill-filter-${kind.name}'),
                        onPressed: () => search.setKind(kind),
                        style: TextButton.styleFrom(
                          foregroundColor: search.kind == kind
                              ? _blue
                              : Colors.black54,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(40, 40),
                          textStyle: TextStyle(
                            fontSize: 12,
                            fontWeight: search.kind == kind
                                ? FontWeight.w600
                                : FontWeight.w300,
                            decoration: search.kind == kind
                                ? TextDecoration.underline
                                : null,
                          ),
                        ),
                        child: Text(_label(kind)),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => Stack(
                children: [
                  Positioned.fill(
                    child: search.selected == null
                        ? widget.contacts
                        : _content(search),
                  ),
                  if (!search.idle &&
                      search.selected == null &&
                      _focus.hasFocus)
                    Positioned(
                      top: 8,
                      left: 37.5,
                      right: 37.5,
                      child: _suggestions(
                        search,
                        math.min(192, math.max(0, constraints.maxHeight - 8)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );

  Widget _content(SkillSearchController search) {
    if (search.error != null) {
      return _SearchStatus(
        text: search.error!,
        action: TextButton(
          onPressed: search.retry,
          child: const Text('Retry search'),
        ),
      );
    }
    if (search.idle) return widget.contacts;
    if (search.loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (search.results.isEmpty) {
      return _SearchStatus(
        text: 'No profiles found for this skill',
        action: widget.onAskCommunity == null
            ? null
            : TextButton(
                onPressed: () => widget.onAskCommunity!(search.selected!.label),
                child: const Text('Ask our community'),
              ),
      );
    }
    return ListView(
      key: const Key('skill-search-results'),
      padding: const EdgeInsets.fromLTRB(37.5, 18, 37.5, 85),
      children: [
        for (final hit in search.results)
          InkWell(
            key: ValueKey('skill-result-${hit.id}'),
            onTap: _opening == null ? () => unawaited(_open(hit)) : null,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 17),
              child: Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      widget.avatarFor(hit),
                      const SizedBox(width: 21),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              hit.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Row(
                                children: [
                                  if (search.kind != SkillSearchKind.all)
                                    Text(
                                      '${_label(search.kind)}: ',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  Flexible(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 5,
                                        vertical: 2,
                                      ),
                                      color: const Color(0xFFFFBFBC),
                                      child: Text(
                                        search.selected!.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w300,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_opening == hit.id)
                              const Padding(
                                padding: EdgeInsets.only(top: 4),
                                child: Text(
                                  'Opening profile…',
                                  style: TextStyle(fontSize: 11, color: _blue),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 17),
                  const Divider(height: 1, color: Color(0xFFCDDEE8)),
                ],
              ),
            ),
          ),
        if (search.pageError != null)
          Text(
            search.pageError!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        if (search.hasMore)
          Center(
            child: search.loadingMore
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton(
                    onPressed: search.loadMore,
                    child: Text(
                      search.pageError == null
                          ? 'Load more'
                          : 'Retry loading more',
                    ),
                  ),
          ),
      ],
    );
  }

  Widget _suggestions(SkillSearchController search, double maxHeight) =>
      TextFieldTapRegion(
        child: Material(
          key: const Key('skill-suggestions'),
          color: const Color(0xFFF4F4F4),
          borderRadius: BorderRadius.circular(4),
          elevation: 4,
          shadowColor: const Color(0x33000000),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                if (search.loading)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Center(
                      child: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else if (search.error != null)
                  ListTile(
                    dense: true,
                    title: Text(
                      search.error!,
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: TextButton(
                      onPressed: search.retry,
                      child: const Text('Retry'),
                    ),
                  )
                else if (search.suggestions.isEmpty)
                  ListTile(
                    dense: true,
                    title: const Text(
                      'Search this skill',
                      style: TextStyle(fontSize: 13),
                    ),
                    onTap: _submit,
                  )
                else
                  for (final skill in search.suggestions)
                    ListTile(
                      key: ValueKey('suggest-${skill.key}'),
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                      ),
                      title: Text(
                        skill.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      onTap: () {
                        _focus.unfocus();
                        unawaited(search.select(skill));
                      },
                    ),
              ],
            ),
          ),
        ),
      );

  @override
  void dispose() {
    widget.controller.removeListener(_syncField);
    _focus.dispose();
    _field.dispose();
    super.dispose();
  }
}

class _SearchStatus extends StatelessWidget {
  const _SearchStatus({required this.text, this.action});
  final String text;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 38),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w300),
          ),
          ?action,
        ],
      ),
    ),
  );
}
