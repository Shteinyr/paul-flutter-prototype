import 'dart:async';
import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import 'chat_api.dart';
import 'browser_storage.dart';

abstract interface class ChatStateStore {
  Future<String?> read(String userId);
  Future<void> write(String userId, String state);
}

class SessionChatStateStore implements ChatStateStore {
  String _key(String userId) => 'paul.live.chat.state.v1.$userId';
  @override
  Future<String?> read(String userId) async => readSessionValue(_key(userId));
  @override
  Future<void> write(String userId, String state) async =>
      writeSessionValue(_key(userId), state);
}

enum ChatDelivery { pending, failed }

class PendingChatMessage {
  PendingChatMessage(this.clientMessageId, this.text);
  final String clientMessageId;
  final String text;
  ChatDelivery delivery = ChatDelivery.pending;
}

class LiveChatController extends ChangeNotifier {
  LiveChatController(
    this.repository,
    this.userId, {
    required ChatStateStore drafts,
    String? senderProfileId,
    bool Function()? canSend,
  }) : _draftStore = drafts,
       senderProfileId = senderProfileId ?? userId,
       _canSend = canSend {
    _identity = repository.identityChanges.listen(
      (id) {
        if (id != userId) _invalidateIdentity();
      },
      onError: (Object _) {
        if (_disposed) return;
        if (repository.currentUserId != userId) {
          _invalidateIdentity();
        } else {
          error =
              'Could not refresh your session. Check your connection and retry.';
          _notify();
        }
      },
    );
  }
  final ChatRepository repository;
  final String userId;
  final String senderProfileId;
  final bool Function()? _canSend;
  bool get canSend => _canSend?.call() ?? true;
  final ChatStateStore _draftStore;
  final _messages = <String, List<ChatMessage>>{};
  final _pending = <String, List<PendingChatMessage>>{};
  final _drafts = <String, String>{};
  final _olderAvailable = <String, bool>{};
  final _loadedThrough = <String, int>{};
  final _readThrough = <String, int>{};
  late final StreamSubscription<String?> _identity;
  StreamSubscription<String>? _signals;
  Timer? _fallback;
  Future<bool> _draftWrites = Future<bool>.value(true);
  Future<void>? _refreshing;
  bool _refreshAgain = false;
  bool _disposed = false;
  bool _signedOut = false;
  bool _resumed = false;
  int _generation = 0;
  int _openGeneration = 0;
  bool loaded = false;
  bool stateLoadFailed = false;
  bool loadingHistory = false;
  bool loadingOlder = false;
  String? error;
  String? activeConversationId;
  List<ChatSummary> conversations = const [];
  void Function(String conversationId)? onConnected;
  VoidCallback? onChanged;

  bool get _valid =>
      !_disposed && !_signedOut && repository.currentUserId == userId;
  bool _current(int generation) => _valid && generation == _generation;
  int get unreadCount =>
      conversations.fold(0, (count, thread) => count + thread.unread);
  List<ChatMessage> messages(String id) =>
      List.unmodifiable(_messages[id] ?? const []);
  List<PendingChatMessage> pending(String id) =>
      List.unmodifiable(_pending[id] ?? const []);
  String draft(String id) => _drafts[id] ?? '';
  bool hasOlder(String id) => _olderAvailable[id] ?? false;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    if (!_valid) return;
    final generation = _generation;
    stateLoadFailed = false;
    try {
      final saved = await _draftStore.read(userId);
      if (!_current(generation)) return;
      // Text typed while storage loads is newer than the stored draft.
      if (saved != null) {
        final state = jsonDecode(saved) as Map;
        final storedDrafts = Map<String, String>.from(state['drafts'] as Map);
        final storedPending = state['pending'] as Map;
        for (final item in storedDrafts.entries) {
          _drafts.putIfAbsent(item.key, () => item.value);
        }
        for (final entry in storedPending.entries) {
          final restored = (entry.value as List)
              .map(
                (value) => PendingChatMessage(
                  value['id'] as String,
                  value['text'] as String,
                )..delivery = ChatDelivery.failed,
              )
              .toList();
          _pending.putIfAbsent(entry.key as String, () => restored);
        }
      }
    } catch (_) {
      if (_current(generation)) {
        stateLoadFailed = true;
        error = 'Could not restore your chat drafts. Please retry.';
        _notify();
      }
      return;
    }
    if (!_current(generation)) return;
    loaded = true;
    resume();
    await refresh();
  }

  void resume() {
    if (!_valid || _resumed) return;
    _resumed = true;
    _signals = repository.watch().listen(
      (_) {
        if (_valid) unawaited(refresh());
      },
      onError: (Object _) {
        // The durable history remains authoritative. The bounded fallback keeps
        // the visible app usable while the SDK reconnects its private channel.
        if (_valid) unawaited(refresh());
      },
    );
    _fallback = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_valid) unawaited(refresh());
    });
    unawaited(refresh());
  }

  void pause() {
    _resumed = false;
    _fallback?.cancel();
    _fallback = null;
    final signals = _signals;
    _signals = null;
    if (signals != null) unawaited(signals.cancel());
  }

  Future<void> refresh() {
    if (!_valid) return Future<void>.value();
    final running = _refreshing;
    if (running != null) {
      _refreshAgain = true;
      return running;
    }
    final operation = _refresh();
    _refreshing = operation;
    return operation;
  }

  Future<void> _refresh() async {
    final generation = _generation;
    try {
      do {
        _refreshAgain = false;
        final list = await repository.list();
        if (!_current(generation)) return;
        conversations = List.unmodifiable(list);
        final id = activeConversationId;
        if (id != null && !loadingHistory) await _catchUp(id, generation);
        if (!_current(generation)) return;
        error = null;
        onChanged?.call();
        _notify();
      } while (_refreshAgain && _current(generation));
    } catch (_) {
      if (_current(generation)) {
        error = 'Could not update your chats. Please retry.';
        _notify();
      }
    } finally {
      _refreshing = null;
    }
  }

  Future<String?> openPeer(String peerId) async {
    if (!_valid) return null;
    final generation = _generation;
    final opening = ++_openGeneration;
    try {
      final id = await repository.open(peerId);
      if (!_current(generation) || opening != _openGeneration) return null;
      await _openConversation(id, opening);
      return _current(generation) && opening == _openGeneration ? id : null;
    } catch (_) {
      if (_current(generation) && opening == _openGeneration) {
        error = 'Could not open this chat. Please retry.';
        _notify();
      }
      return null;
    }
  }

  Future<void> openConversation(String id) =>
      _openConversation(id, ++_openGeneration);

  Future<void> _openConversation(String id, int opening) async {
    if (!_valid) return;
    final generation = _generation;
    activeConversationId = id;
    loadingHistory = true;
    loadingOlder = false;
    error = null;
    _notify();
    try {
      final page = await repository.history(id);
      if (!_current(generation) || opening != _openGeneration) return;
      _merge(id, page.messages);
      _loadedThrough[id] = page.messages.lastOrNull?.sequence ?? 0;
      _olderAvailable[id] =
          page.messages.isNotEmpty && page.messages.first.sequence > 1;
      await _markVisibleRead(id, generation);
    } catch (_) {
      if (_current(generation) && opening == _openGeneration) {
        error = 'Could not load this chat. Please retry.';
      }
    } finally {
      if (_current(generation) && opening == _openGeneration) {
        loadingHistory = false;
        _notify();
      }
    }
    if (_current(generation) && opening == _openGeneration) await refresh();
  }

  void closeConversation() {
    ++_openGeneration;
    activeConversationId = null;
    loadingHistory = false;
    loadingOlder = false;
  }

  Future<void> loadOlder() async {
    final id = activeConversationId;
    if (!_valid || id == null || loadingOlder || !hasOlder(id)) return;
    final generation = _generation;
    final opening = _openGeneration;
    loadingOlder = true;
    _notify();
    try {
      final before = _messages[id]!.first.sequence;
      final page = await repository.history(id, before: before);
      if (!_current(generation)) return;
      _merge(id, page.messages);
      _olderAvailable[id] =
          page.messages.isNotEmpty && page.messages.first.sequence > 1;
    } catch (_) {
      if (_current(generation) && opening == _openGeneration) {
        error = 'Could not load older messages. Please retry.';
      }
    } finally {
      if (_current(generation) && opening == _openGeneration) {
        loadingOlder = false;
        _notify();
      }
    }
  }

  void _merge(String id, List<ChatMessage> incoming) {
    final bySequence = {
      for (final item in _messages[id] ?? <ChatMessage>[]) item.sequence: item,
    };
    for (final item in incoming) {
      if (item.conversationId == id) bySequence[item.sequence] = item;
      if (item.conversationId == id &&
          item.senderId == senderProfileId &&
          item.actorUserId == userId) {
        final acknowledged = _pending[id]
            ?.where(
              (pending) => pending.clientMessageId == item.clientMessageId,
            )
            .firstOrNull;
        if (acknowledged != null) {
          _pending[id]!.remove(acknowledged);
          if (draft(id) == acknowledged.text) {
            _drafts[id] = '';
          }
          unawaited(_saveDrafts());
        }
      }
    }
    _messages[id] = bySequence.values.toList()
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
  }

  Future<void> _catchUp(String id, int generation) async {
    var after = _loadedThrough[id];
    while (_current(generation) && activeConversationId == id) {
      final page = await repository.history(id, after: after);
      if (!_current(generation) || activeConversationId != id) return;
      if (after == null) {
        _olderAvailable[id] =
            page.messages.isNotEmpty && page.messages.first.sequence > 1;
      }
      _merge(id, page.messages);
      if (page.messages.isEmpty) break;
      after = page.messages.last.sequence;
      _loadedThrough[id] = after;
      if (after >= page.lastSequence) break;
    }
    await _markVisibleRead(id, generation);
  }

  Future<void> _markVisibleRead(String id, int generation) async {
    if (!_current(generation) || !_resumed || activeConversationId != id) {
      return;
    }
    final through = _messages[id]?.lastOrNull?.sequence;
    if (through != null && through > (_readThrough[id] ?? 0)) {
      await repository.read(id, through);
      if (!_current(generation)) return;
      _readThrough[id] = through;
      _refreshAgain = true;
    }
  }

  void updateDraft(String id, String text) {
    if (!_valid) return;
    _drafts[id] = text;
    _saveDrafts();
    _notify();
  }

  Future<bool> _saveDrafts() {
    final snapshot = jsonEncode({
      'drafts': _drafts,
      'pending': {
        for (final entry in _pending.entries)
          entry.key: entry.value
              .map((item) => {'id': item.clientMessageId, 'text': item.text})
              .toList(),
      },
    });
    _draftWrites = _draftWrites.then((_) async {
      try {
        await _draftStore.write(userId, snapshot);
        return true;
      } catch (_) {
        if (_valid) {
          error = 'Could not save your chat. Please retry.';
          _notify();
        }
        return false;
      }
    });
    return _draftWrites;
  }

  Future<void> flushDrafts() async {
    await _draftWrites;
  }

  Future<bool> send(String id, String text) async {
    if (!_valid ||
        !loaded ||
        stateLoadFailed ||
        !canSend ||
        text.trim().isEmpty ||
        text.contains('\u0000') ||
        text.characters.length > 2000 ||
        utf8.encode(text).length > 65536) {
      return false;
    }
    final existing = _pending[id]
        ?.where((item) => item.text == text)
        .firstOrNull;
    if (existing != null) return retry(id, existing.clientMessageId);
    final item = PendingChatMessage(newChatOperationId(), text);
    (_pending[id] ??= []).add(item);
    updateDraft(id, text);
    return _send(id, item);
  }

  Future<bool> retry(String id, String clientMessageId) async {
    final item = _pending[id]
        ?.where((value) => value.clientMessageId == clientMessageId)
        .firstOrNull;
    if (!_valid ||
        !loaded ||
        stateLoadFailed ||
        item == null ||
        item.delivery == ChatDelivery.pending) {
      return false;
    }
    item.delivery = ChatDelivery.pending;
    return _send(id, item);
  }

  Future<bool> _send(String id, PendingChatMessage item) async {
    if (!canSend) return false;
    final generation = _generation;
    error = null;
    _notify();
    try {
      // Save the operation ID and exact payload before any request can commit.
      if (!await _saveDrafts()) {
        throw const ChatException('storage_unavailable');
      }
      if (!_current(generation)) return false;
      final result = await repository.send(id, item.clientMessageId, item.text);
      if (!_current(generation)) return false;
      if (result.message.clientMessageId != item.clientMessageId ||
          result.message.senderId != senderProfileId ||
          result.message.actorUserId != userId ||
          result.message.conversationId != id) {
        throw const ChatException('server_unavailable');
      }
      _merge(id, [result.message]);
      if (result.connected && !result.replayed) onConnected?.call(id);
      _notify();
      await refresh();
      return _current(generation);
    } catch (problem) {
      if (_current(generation)) {
        item.delivery = ChatDelivery.failed;
        error = problem is ChatException
            ? problem.toString()
            : 'Could not send your message. Please retry.';
        _notify();
      }
      return false;
    }
  }

  void _invalidateIdentity() {
    if (_disposed) return;
    _signedOut = true;
    ++_generation;
    ++_openGeneration;
    pause();
    _messages.clear();
    _pending.clear();
    _drafts.clear();
    _olderAvailable.clear();
    _loadedThrough.clear();
    _readThrough.clear();
    loaded = false;
    conversations = const [];
    activeConversationId = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    pause();
    unawaited(_identity.cancel());
    super.dispose();
  }
}
