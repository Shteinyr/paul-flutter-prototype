import 'dart:async';

import 'package:flutter/material.dart';

import 'skill_search_api.dart';
import 'skill_search_controller.dart';
import '../skills/skill_suggestions.dart';

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
  String? _opening;

  @override
  void initState() {
    super.initState();
    _syncField();
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
              onChanged: search.setQuery,
              onSubmitted: (_) => unawaited(search.submit()),
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
          if (!search.idle)
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
                        child: Text(kind.label),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(child: _content(search)),
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
    if (search.selected == null) {
      if (search.suggestions.isEmpty) {
        return _SearchStatus(
          text: 'No matching skills',
          action: TextButton(
            onPressed: search.submit,
            child: const Text('Search this skill'),
          ),
        );
      }
      return ListView(
        key: const Key('skill-suggestions'),
        padding: const EdgeInsets.fromLTRB(37.5, 4, 37.5, 80),
        children: [
          for (final skill in search.suggestions)
            ListTile(
              key: ValueKey('suggest-${skill.key}'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              title: Text(
                skill.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w300,
                ),
              ),
              trailing: const Icon(Icons.north_west, size: 16, color: _blue),
              onTap: () {
                FocusScope.of(context).unfocus();
                unawaited(search.select(skill));
              },
            ),
          TextButton(
            onPressed: () => showSkillCatalogueAttribution(context),
            child: const Text(
              'Skill catalogue source',
              style: TextStyle(fontSize: 10),
            ),
          ),
        ],
      );
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
                            for (final kind in hit.matchedKinds)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Row(
                                  children: [
                                    Text(
                                      '${kind.label} ',
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                    Flexible(
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                          vertical: 2,
                                        ),
                                        color: kind == SkillSearchKind.offering
                                            ? const Color(0xFFFFBFBC)
                                            : const Color(0xFFD5E8F5),
                                        child: Text(
                                          search.selected!.label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 11,
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

  @override
  void dispose() {
    widget.controller.removeListener(_syncField);
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
