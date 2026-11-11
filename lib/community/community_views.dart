import 'dart:async';

import 'package:flutter/material.dart';

import '../live/chat_api.dart';
import '../live/member_capabilities.dart';
import '../skills/skill_suggestions.dart';
import 'community_api.dart';
import 'community_controller.dart';

const _blue = Color(0xFF14679E);

typedef CommunityMessage = Future<void> Function(BuildContext, ChatPeer);

class CommunityFeedView extends StatefulWidget {
  const CommunityFeedView({
    super.key,
    required this.controller,
    required this.onMessage,
    required this.onInvite,
    required this.avatarFor,
  });
  final CommunityController controller;
  final CommunityMessage onMessage;
  final VoidCallback onInvite;
  final Widget Function(ChatPeer) avatarFor;

  @override
  State<CommunityFeedView> createState() => _CommunityFeedViewState();
}

class _CommunityFeedViewState extends State<CommunityFeedView>
    with WidgetsBindingObserver {
  Timer? _refreshTimer;
  bool _resumed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(widget.controller.refresh());
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_resumed && ModalRoute.of(context)?.isCurrent == true) {
        unawaited(widget.controller.refresh());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (_resumed) unawaited(widget.controller.refresh());
  }

  Future<void> _compose() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CommunityComposeView(
          controller: widget.controller,
          onInvite: widget.onInvite,
        ),
      ),
    );
    if (mounted) unawaited(widget.controller.refresh());
  }

  Future<void> _open(CommunityRequest request) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CommunityDetailView(
          controller: widget.controller,
          requestId: request.id,
          onMessage: widget.onMessage,
          avatarFor: widget.avatarFor,
        ),
      ),
    );
    if (mounted) unawaited(widget.controller.refresh());
  }

  @override
  Widget build(BuildContext context) => _CommunityFrame(
    title: 'Hiring',
    actions: [
      IconButton(
        tooltip: 'Refresh hiring',
        onPressed: widget.controller.refresh,
        icon: const Icon(Icons.refresh),
      ),
    ],
    child: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final requests = controller.requests
            .where((item) => item.expiresAt.isAfter(controller.serverNow))
            .toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 8, 32, 12),
              child: FilledButton(
                onPressed: controller.current ? _compose : null,
                child: const Text('Ask our community'),
              ),
            ),
            if (controller.error != null)
              _Status(controller.error!, onRetry: controller.refresh),
            Expanded(
              child: RefreshIndicator(
                onRefresh: controller.refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(32, 12, 32, 32),
                  children: [
                    if (controller.loading && requests.isEmpty)
                      const Center(child: CircularProgressIndicator()),
                    if (!controller.loading && requests.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 40),
                        child: Text(
                          'No active requests yet',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    for (var index = 0; index < requests.length; index++) ...[
                      if (index == 0 ||
                          _group(requests[index]) !=
                              _group(requests[index - 1]))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16, top: 8),
                          child: Text(
                            _group(requests[index]),
                            style: const TextStyle(
                              color: Colors.black54,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      InkWell(
                        key: ValueKey('community-${requests[index].id}'),
                        onTap: () => _open(requests[index]),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: _RequestBody(
                            request: requests[index],
                            avatar: widget.avatarFor(requests[index].author),
                            compact: true,
                          ),
                        ),
                      ),
                      const Divider(color: Color(0xFFDFE7EB)),
                    ],
                    if (controller.pageError != null)
                      _Status(
                        controller.pageError!,
                        onRetry: controller.loadMore,
                      ),
                    if (controller.hasMore)
                      TextButton(
                        onPressed: controller.loadingMore
                            ? null
                            : controller.loadMore,
                        child: Text(
                          controller.loadingMore ? 'Loading…' : 'Load more',
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    ),
  );

  String _group(CommunityRequest request) {
    final age = widget.controller.serverNow.difference(request.createdAt);
    if (age < const Duration(days: 1)) return 'Today';
    if (age < const Duration(days: 7)) return 'Last week';
    return 'Earlier';
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class CommunityComposeView extends StatefulWidget {
  const CommunityComposeView({
    super.key,
    required this.controller,
    required this.onInvite,
    this.initialSkill = '',
  });
  final CommunityController controller;
  final VoidCallback onInvite;
  final String initialSkill;

  @override
  State<CommunityComposeView> createState() => _CommunityComposeViewState();
}

class _CommunityComposeViewState extends State<CommunityComposeView>
    with WidgetsBindingObserver {
  final _skill = TextEditingController();
  final _message = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_sync);
    unawaited(
      widget.controller.prepareDraft(initialSkill: widget.initialSkill),
    );
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.controller.refreshCapabilities());
    } else {
      unawaited(widget.controller.flushDraft());
    }
  }

  void _sync() {
    _setText(_skill, widget.controller.skill);
    _setText(_message, widget.controller.message);
  }

  void _setText(TextEditingController field, String text) {
    if (field.text == text) return;
    field.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> _publish() async {
    FocusScope.of(context).unfocus();
    final receipt = await widget.controller.publish();
    if (!mounted || receipt == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          receipt.active
              ? 'Request published'
              : 'This request is no longer active',
        ),
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => _CommunityFrame(
    title: 'Ask our community',
    child: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final level = controller.capabilities;
        final pending = controller.pendingPublish;
        final allowed = level?.canPublishCommunity == true || pending;
        final editing =
            controller.current &&
            controller.draftReady &&
            allowed &&
            !pending &&
            !controller.publishing;
        return ListView(
          padding: const EdgeInsets.fromLTRB(32, 16, 32, 40),
          children: [
            if (level == null || !level.canPublishCommunity)
              MemberLevelStatus(
                capabilities: level,
                error: controller.capabilityError,
                onRefresh: controller.refreshCapabilities,
                onInvite: widget.onInvite,
              ),
            if (!controller.draftReady && controller.draftError == null)
              const Center(child: CircularProgressIndicator()),
            TextField(
              key: const Key('community-skill'),
              controller: _skill,
              focusNode: _focus,
              enabled: editing,
              maxLength: 64,
              decoration: const InputDecoration(labelText: 'Skill you need'),
              onChanged: (value) => controller.updateDraft(skill: value),
            ),
            SkillSuggestions(
              controller: _skill,
              focusNode: _focus,
              selected: const [],
              enabled: editing,
              onSelected: (value) {
                controller.updateDraft(skill: value);
                _focus.unfocus();
              },
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('community-message'),
              controller: _message,
              enabled: editing,
              minLines: 5,
              maxLines: 12,
              maxLength: 2000,
              decoration: const InputDecoration(labelText: 'How can we help?'),
              onChanged: (value) => controller.updateDraft(message: value),
            ),
            const SizedBox(height: 12),
            const Text(
              'Your request stays in Hiring for 30 days. Close it when you find help.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            if (pending)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Text(
                  'Your submission is saved. Retry to check its result.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            if (controller.draftError != null)
              _Status(
                controller.draftError!,
                onRetry: () async {
                  if (controller.draftReady) {
                    await controller.flushDraft();
                  } else {
                    await controller.prepareDraft();
                  }
                },
              ),
            if (controller.publishError != null)
              _Status(controller.publishError!),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('community-publish'),
              onPressed:
                  controller.current &&
                      controller.draftReady &&
                      allowed &&
                      !controller.publishing
                  ? _publish
                  : null,
              child: Text(
                controller.publishing
                    ? 'Submitting…'
                    : pending
                    ? 'Retry submission'
                    : 'Publish request',
              ),
            ),
          ],
        );
      },
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_sync);
    unawaited(widget.controller.flushDraft());
    _skill.dispose();
    _message.dispose();
    _focus.dispose();
    super.dispose();
  }
}

class CommunityDetailView extends StatefulWidget {
  const CommunityDetailView({
    super.key,
    required this.controller,
    required this.requestId,
    required this.onMessage,
    required this.avatarFor,
  });
  final CommunityController controller;
  final String requestId;
  final CommunityMessage onMessage;
  final Widget Function(ChatPeer) avatarFor;

  @override
  State<CommunityDetailView> createState() => _CommunityDetailViewState();
}

class _CommunityDetailViewState extends State<CommunityDetailView>
    with WidgetsBindingObserver {
  CommunityRequest? _request;
  String? _error;
  bool _loading = true;
  bool _closing = false;
  bool _resumed = true;
  Timer? _timer;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_resumed && !_closing && ModalRoute.of(context)?.isCurrent == true) {
        unawaited(_refresh());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (_resumed && !_closing) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    try {
      final request = await widget.controller.repository.get(widget.requestId);
      if (!mounted || !widget.controller.current || generation != _generation) {
        return;
      }
      setState(() {
        _request = request;
        _loading = false;
        _error = null;
      });
    } catch (failure) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = failure is CommunityException
            ? failure.toString()
            : const CommunityException('server_unavailable').toString();
      });
    }
  }

  Future<void> _close() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Close this request?'),
        content: const Text('This removes your request from Hiring.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Close request'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _generation++;
    setState(() => _closing = true);
    final closed = await widget.controller.closeRequest(widget.requestId);
    if (!mounted) return;
    setState(() {
      _closing = false;
      _error = closed ? null : widget.controller.error;
      if (closed) _request = null;
    });
  }

  Future<void> _messageAuthor() async {
    // Re-read before opening a conversation reached through an old feed or push.
    await _refresh();
    if (!mounted || _request == null || _error != null) return;
    await widget.onMessage(context, _request!.author);
  }

  @override
  Widget build(BuildContext context) => _CommunityFrame(
    title: 'Hiring request',
    actions: [
      IconButton(
        tooltip: 'Refresh request',
        onPressed: _refresh,
        icon: const Icon(Icons.refresh),
      ),
    ],
    child: ListView(
      padding: const EdgeInsets.fromLTRB(32, 16, 32, 40),
      children: [
        if (_loading) const Center(child: CircularProgressIndicator()),
        if (_error != null) _Status(_error!, onRetry: _refresh),
        if (!_loading && _request == null && _error == null)
          const Text('This request is no longer available.'),
        if (_request case final request?) ...[
          _RequestBody(
            request: request,
            avatar: widget.avatarFor(request.author),
          ),
          const SizedBox(height: 24),
          if (request.isAuthor)
            OutlinedButton(
              onPressed: _closing ? null : _close,
              child: Text(_closing ? 'Closing…' : 'Close request'),
            )
          else
            FilledButton(
              onPressed: _messageAuthor,
              child: const Text('Message author'),
            ),
        ],
      ],
    ),
  );

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class _RequestBody extends StatelessWidget {
  const _RequestBody({
    required this.request,
    required this.avatar,
    this.compact = false,
  });
  final CommunityRequest request;
  final Widget avatar;
  final bool compact;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          avatar,
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(request.author.name, style: const TextStyle(fontSize: 15)),
                if (request.author.occupation.isNotEmpty)
                  Text(
                    request.author.occupation,
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Text(request.skill, style: const TextStyle(color: _blue, fontSize: 17)),
      const SizedBox(height: 8),
      Text(
        request.message,
        maxLines: compact ? 3 : null,
        overflow: compact ? TextOverflow.ellipsis : null,
        style: const TextStyle(fontSize: 14, height: 1.5),
      ),
    ],
  );
}

class _CommunityFrame extends StatelessWidget {
  const _CommunityFrame({
    required this.title,
    required this.child,
    this.actions,
  });
  final String title;
  final Widget child;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.white,
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 448),
        child: SafeArea(
          child: Column(
            children: [
              AppBar(
                title: Text(title, style: const TextStyle(fontSize: 18)),
                backgroundColor: Colors.white,
                surfaceTintColor: Colors.transparent,
                actions: actions,
              ),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Status extends StatelessWidget {
  const _Status(this.text, {this.onRetry});
  final String text;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
    child: Column(
      children: [
        Text(text, textAlign: TextAlign.center),
        if (onRetry != null)
          TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    ),
  );
}
