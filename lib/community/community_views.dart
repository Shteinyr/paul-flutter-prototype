import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../live/chat_api.dart';
import '../profile/public_profile_view.dart';
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
    this.embedded = false,
  });
  final bool embedded;
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
  final _scroll = ScrollController();
  final _rowKeys = <String, GlobalKey>{};
  List<CommunityRequest>? _shownRequests;
  int _anchorGeneration = 0;
  bool _resumed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_preservePosition);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.controller.refresh());
    });
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_resumed && ModalRoute.of(context)?.isCurrent == true) {
        unawaited(widget.controller.refresh());
      }
    });
  }

  @override
  void didUpdateWidget(CommunityFeedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_preservePosition);
      widget.controller.addListener(_preservePosition);
      _shownRequests = null;
      _anchorGeneration++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(widget.controller.refresh());
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (_resumed) {
      widget.controller.expireRequests();
      unawaited(widget.controller.refresh());
    }
  }

  void _preservePosition() {
    final requests = widget.controller.requests;
    if (identical(requests, _shownRequests)) return;
    _shownRequests = requests;
    final generation = ++_anchorGeneration;
    final ids = requests.map((item) => item.id).toSet();
    String? anchorId;
    double? top;
    final offset = _scroll.hasClients ? _scroll.offset : null;
    if (offset != null && offset > 0) {
      for (final entry in _rowKeys.entries) {
        if (!ids.contains(entry.key)) continue;
        final box = entry.value.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.attached || !box.hasSize) continue;
        final viewport = RenderAbstractViewport.of(box);
        final y = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
        if (y + box.size.height > 0 && (top == null || y < top)) {
          anchorId = entry.key;
          top = y;
        }
      }
    }
    if (anchorId != null && top != null && offset != null) {
      _restorePosition(anchorId, top, offset, generation, 0);
    }
    _rowKeys.removeWhere((id, _) => !ids.contains(id));
  }

  void _restorePosition(
    String id,
    double top,
    double expectedOffset,
    int generation,
    int attempt,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _anchorGeneration ||
          !_scroll.hasClients ||
          (_scroll.offset - expectedOffset).abs() > .5) {
        return;
      }
      final anchor = _rowKeys[id]?.currentContext?.findRenderObject();
      double? target;
      if (anchor is RenderBox && anchor.attached && anchor.hasSize) {
        final y = anchor
            .localToGlobal(
              Offset.zero,
              ancestor: RenderAbstractViewport.of(anchor),
            )
            .dy;
        target = _scroll.offset + y - top;
      } else if (attempt < 6) {
        // A burst of arrivals can move the anchor outside the lazy viewport.
        // Seek using a laid-out neighbour, then correct to its exact position
        // on the next frame. Do not eagerly lay out/download every avatar.
        final requests = widget.controller.requests;
        final index = requests.indexWhere((item) => item.id == id);
        var nearest = requests.length;
        for (var row = 0; row < requests.length; row++) {
          final distance = (index - row).abs();
          if (distance >= nearest) continue;
          final box = _rowKeys[requests[row].id]?.currentContext
              ?.findRenderObject();
          if (box is! RenderBox || !box.attached || !box.hasSize) continue;
          nearest = distance;
          final y = box
              .localToGlobal(
                Offset.zero,
                ancestor: RenderAbstractViewport.of(box),
              )
              .dy;
          target =
              _scroll.offset + y - top + (index - row) * (box.size.height + 16);
        }
      }
      if (target == null) return;
      final next = target.clamp(
        _scroll.position.minScrollExtent,
        _scroll.position.maxScrollExtent,
      );
      if ((next - _scroll.offset).abs() <= .5) return;
      _scroll.jumpTo(next);
      if (anchor == null && attempt < 6) {
        _restorePosition(id, top, next, generation, attempt + 1);
      }
    });
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
  Widget build(BuildContext context) {
    final content = ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final requests = controller.requests
            .where((item) => item.expiresAt.isAfter(controller.serverNow))
            .toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (controller.error != null)
              _Status(controller.error!, onRetry: controller.refresh),
            Expanded(
              child: RefreshIndicator(
                onRefresh: controller.refresh,
                child: ListView(
                  key: const Key('community-feed'),
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(37.5, 47, 37.5, 40),
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
                              color: Colors.black,
                              fontSize: 20,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ),
                      InkWell(
                        key: ValueKey('community-${requests[index].id}'),
                        onTap: () => _open(requests[index]),
                        child: Padding(
                          key: _rowKeys.putIfAbsent(
                            requests[index].id,
                            GlobalKey.new,
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: HiringRequestRow(
                            name: requests[index].author.name,
                            skill: requests[index].skill,
                            avatar: widget.avatarFor(requests[index].author),
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
    );
    return widget.embedded
        ? content
        : _CommunityFrame(title: 'Hiring', child: content);
  }

  String _group(CommunityRequest request) {
    final age = widget.controller.serverNow.difference(request.createdAt);
    if (age < const Duration(days: 1)) return 'Today';
    if (age < const Duration(days: 7)) return 'Last Week';
    return 'Earlier';
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    widget.controller.removeListener(_preservePosition);
    _scroll.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class CommunityComposeView extends StatefulWidget {
  const CommunityComposeView({
    super.key,
    required this.controller,
    required this.onInvite,
    this.onPublishLimit,
    this.initialSkill = '',
  });
  final CommunityController controller;
  final VoidCallback onInvite;
  final VoidCallback? onPublishLimit;
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
    if (!widget.controller.pendingPublish &&
        widget.controller.capabilities?.canPublishCommunity != true) {
      widget.onPublishLimit?.call();
      return;
    }
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
    title: 'Skill Search',
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
            !pending &&
            !controller.publishing;
        return ListView(
          padding: const EdgeInsets.fromLTRB(32, 16, 32, 40),
          children: [
            const Center(
              child: SizedBox(
                width: 236,
                child: Text(
                  'Community will be notified. Once skill is found, you may remove from profile.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    height: 22 / 12,
                    fontWeight: FontWeight.w300,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 50),
            if (!controller.draftReady && controller.draftError == null)
              const Center(child: CircularProgressIndicator()),
            TextField(
              key: const Key('community-skill'),
              controller: _skill,
              focusNode: _focus,
              enabled: editing,
              maxLength: 64,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w300),
              decoration: const InputDecoration(
                hintText: 'Skill you need',
                counterText: '',
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFFCDDEE8)),
                ),
              ),
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
              minLines: 1,
              maxLines: 6,
              maxLength: 2000,
              style: const TextStyle(fontSize: 13, height: 1.5),
              decoration: const InputDecoration(
                hintText: 'Message',
                counterText: '',
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFFCDDEE8)),
                ),
              ),
              onChanged: (value) => controller.updateDraft(message: value),
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
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const Key('community-publish'),
                icon: const Icon(Icons.send_outlined, size: 22),
                onPressed:
                    controller.current &&
                        controller.draftReady &&
                        (allowed ||
                            (level != null && widget.onPublishLimit != null)) &&
                        !controller.publishing
                    ? _publish
                    : null,
                label: Text(
                  controller.publishing
                      ? 'Submitting…'
                      : pending
                      ? 'Retry submission'
                      : 'Publish request',
                ),
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
  bool _openingMessage = false;
  bool _resumed = true;
  Future<void>? _refreshing;
  Timer? _timer;
  Timer? _expiryTimer;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_scheduleExpiry);
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_resumed && !_closing && ModalRoute.of(context)?.isCurrent == true) {
        unawaited(_refresh());
      }
    });
  }

  @override
  void didUpdateWidget(CommunityDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.requestId != widget.requestId) {
      oldWidget.controller.removeListener(_scheduleExpiry);
      widget.controller.addListener(_scheduleExpiry);
      _expiryTimer?.cancel();
      _generation++;
      _refreshing = null;
      _request = null;
      unawaited(_refresh());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _scheduleExpiry();
    if (_resumed && !_closing) unawaited(_refresh());
  }

  void _scheduleExpiry() {
    _expiryTimer?.cancel();
    final request = _request;
    if (!mounted ||
        !_resumed ||
        !widget.controller.current ||
        request == null) {
      return;
    }
    _expiryTimer = Timer(widget.controller.expiryDelay(request.expiresAt), () {
      if (!mounted || !widget.controller.current) return;
      if (!request.expiresAt.isAfter(widget.controller.serverNow)) {
        setState(() {
          _request = null;
          _loading = false;
        });
      }
      _scheduleExpiry();
    });
  }

  Future<void> _refresh() {
    if (!mounted || !widget.controller.current || _closing) {
      return Future.value();
    }
    final running = _refreshing;
    if (running != null) return running;
    final operation = _fetch();
    _refreshing = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_refreshing, operation)) _refreshing = null;
      }),
    );
    return operation;
  }

  Future<void> _fetch() async {
    final generation = ++_generation;
    setState(() {
      if (_request?.expiresAt.isAfter(widget.controller.serverNow) != true) {
        _request = null;
      }
      _loading = _request == null;
      _error = null;
    });
    try {
      final request = await widget.controller.repository.get(widget.requestId);
      if (!mounted || !widget.controller.current || generation != _generation) {
        return;
      }
      setState(() {
        _request =
            request?.expiresAt.isAfter(widget.controller.serverNow) == true
            ? request
            : null;
        _loading = false;
        _error = null;
      });
      _scheduleExpiry();
    } catch (failure) {
      if (!mounted || !widget.controller.current || generation != _generation) {
        return;
      }
      setState(() {
        _loading = false;
        if (failure is CommunityException &&
            const {
              'sign_in_required',
              'session_revoked',
              'membership_required',
              'community_forbidden',
            }.contains(failure.code)) {
          _request = null;
        }
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
    _refreshing = null;
    setState(() => _closing = true);
    final closed = await widget.controller.closeRequest(widget.requestId);
    if (!mounted) return;
    setState(() {
      _closing = false;
      _loading = false;
      _error = closed ? null : widget.controller.error;
      if (closed) _request = null;
    });
    _scheduleExpiry();
  }

  Future<void> _messageAuthor() async {
    if (_openingMessage) return;
    setState(() => _openingMessage = true);
    try {
      // Re-read before opening a conversation reached through an old feed or push.
      await _refresh();
      if (!mounted ||
          !widget.controller.current ||
          ModalRoute.of(context)?.isCurrent != true ||
          _request == null ||
          _error != null ||
          !_request!.expiresAt.isAfter(widget.controller.serverNow)) {
        return;
      }
      await widget.onMessage(context, _request!.author);
    } finally {
      if (mounted) setState(() => _openingMessage = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => !widget.controller.current
        ? const _CommunityFrame(
            title: 'Hiring request',
            child: Center(child: Text('Please sign in again to continue.')),
          )
        : _detail(context),
  );

  Widget _detail(BuildContext context) => _CommunityFrame(
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
        if (!_loading &&
            (_request == null ||
                !_request!.expiresAt.isAfter(widget.controller.serverNow)) &&
            _error == null)
          const Text('This request is no longer available.'),
        if (_request case final request?
            when request.expiresAt.isAfter(widget.controller.serverNow)) ...[
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
              onPressed: _openingMessage ? null : _messageAuthor,
              child: const Text('Message author'),
            ),
        ],
      ],
    ),
  );

  @override
  void dispose() {
    _timer?.cancel();
    _expiryTimer?.cancel();
    widget.controller.removeListener(_scheduleExpiry);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class _RequestBody extends StatelessWidget {
  const _RequestBody({required this.request, required this.avatar});
  final CommunityRequest request;
  final Widget avatar;

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
      Text(request.message, style: const TextStyle(fontSize: 14, height: 1.5)),
    ],
  );
}

class HiringRequestRow extends StatelessWidget {
  const HiringRequestRow({
    super.key,
    required this.name,
    required this.skill,
    required this.avatar,
  });
  final String name;
  final String skill;
  final Widget avatar;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      avatar,
      const SizedBox(width: 21),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 9),
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'Urgent Hiring:  '),
                  TextSpan(text: skill),
                ],
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w300),
            ),
          ],
        ),
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
  Widget build(BuildContext context) => ProfilePage(
    title: title,
    action: actions == null
        ? null
        : Row(mainAxisSize: MainAxisSize.min, children: actions!),
    child: child,
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
