import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../demo_contacts.dart';

abstract interface class DemoChatStore {
  Future<String?> read();
  Future<void> write(String value);
}

class PreferencesDemoChatStore implements DemoChatStore {
  final _preferences = SharedPreferencesAsync();
  static const key = 'paul.demo.chat.v1';
  @override
  Future<String?> read() => _preferences.getString(key);
  @override
  Future<void> write(String value) => _preferences.setString(key, value);
}

class DemoMessage {
  const DemoMessage(this.text, {required this.outgoing});
  final String text;
  final bool outgoing;
  Map<String, Object> toJson() => {'text': text, 'outgoing': outgoing};
}

class DemoConversation {
  DemoConversation(this.contactId);
  final String contactId;
  final List<DemoMessage> _messages = [];
  List<DemoMessage> get messages => List.unmodifiable(_messages);
  int unread = 0;
  int connectionStart = 0;
  String draft = '';
  Map<String, Object> toJson() => {
    'id': contactId,
    'messages': _messages.map((m) => m.toJson()).toList(),
    'unread': unread,
    'connectionStart': connectionStart,
    'draft': draft,
  };
}

/// All received messages and notifications are simulated locally.
class DemoChatController extends ChangeNotifier {
  DemoChatController({
    DemoChatStore? store,
    this.replyDelay = const Duration(milliseconds: 1200),
  }) : _store = store {
    _seed();
  }
  final DemoChatStore? _store;
  final Duration replyDelay;
  final _threads = <String, DemoConversation>{};
  final _connected = <String>{};
  final _replyTimers = <String, List<Timer>>{};
  Timer? _saveTimer;
  Future<void> _queue = Future<void>.value();
  bool _disposed = false;
  int _revision = 0;
  int _savedRevision = 0;
  bool loaded = true;
  bool loadFailed = false;
  String? error;
  String? activeContactId;
  bool notificationChoiceMade = false;
  bool notificationsEnabled = false;
  VoidCallback? onConnected;
  void Function(DemoContact, String)? onNotification;

  List<DemoConversation> get conversations =>
      _threads.values.toList().reversed.toList();
  List<DemoContact> get contacts =>
      _connected.map((id) => demoPeople[id]!).toList();
  bool isConnected(String id) => _connected.contains(id);
  int get unreadCount => _threads.values.fold(0, (sum, t) => sum + t.unread);

  void _seed() {
    _threads.clear();
    _connected
      ..clear()
      ..addAll(demoContacts.map((c) => c.id));
    final welcome = DemoConversation(demoChatContact.id)
      .._messages.add(const DemoMessage('Hey, Welcome!', outgoing: false))
      ..unread = 1;
    _threads[welcome.contactId] = welcome;
  }

  Future<void> load() async {
    loaded = false;
    loadFailed = false;
    error = null;
    _notify();
    try {
      final value = await _store?.read();
      if (value != null) _decode(value);
      loaded = true;
      if (value == null) {
        _revision++;
        await flush();
      }
    } catch (_) {
      loadFailed = true;
      error = 'Could not load your chats. Please try again.';
    }
    _notify();
  }

  DemoConversation ensureConversation(String id) {
    if (!demoPeople.containsKey(id)) throw ArgumentError('Unknown contact');
    final existing = _threads[id];
    if (existing != null) return existing;
    final thread = DemoConversation(id);
    _threads[id] = thread;
    _changed();
    return thread;
  }

  void open(String id) {
    final thread = ensureConversation(id);
    activeContactId = id;
    if (thread.unread != 0) {
      thread.unread = 0;
      _changed();
    }
  }

  void close(String id) {
    if (activeContactId == id) activeContactId = null;
  }

  void updateDraft(String id, String text) {
    if (!loaded || loadFailed) return;
    ensureConversation(id).draft = text;
    _changed();
  }

  bool send(String id, String text) {
    final trimmed = text.trim();
    if (!loaded ||
        loadFailed ||
        !demoPeople.containsKey(id) ||
        trimmed.isEmpty ||
        trimmed.length > 2000) {
      return false;
    }
    final thread = ensureConversation(id);
    thread._messages.add(DemoMessage(trimmed, outgoing: true));
    thread.draft = '';
    _bringToFront(thread);
    _connectIfMutual(thread);
    _changed();
    late final Timer timer;
    timer = Timer(replyDelay, () {
      _replyTimers[id]?.remove(timer);
      if (_disposed) return;
      receive(id, 'Thanks for your message! Let’s keep in touch.');
    });
    _replyTimers.putIfAbsent(id, () => []).add(timer);
    return true;
  }

  void receive(String id, String text) {
    if (!loaded ||
        loadFailed ||
        !demoPeople.containsKey(id) ||
        text.trim().isEmpty) {
      return;
    }
    final thread = ensureConversation(id);
    thread._messages.add(DemoMessage(text.trim(), outgoing: false));
    if (activeContactId != id) thread.unread++;
    _bringToFront(thread);
    _connectIfMutual(thread);
    _changed();
    if (notificationsEnabled && activeContactId != id) {
      onNotification?.call(demoPeople[id]!, text.trim());
    }
  }

  void _bringToFront(DemoConversation thread) {
    _threads.remove(thread.contactId);
    _threads[thread.contactId] = thread;
  }

  void _connectIfMutual(DemoConversation thread) {
    if (isConnected(thread.contactId)) return;
    final exchange = thread._messages.skip(thread.connectionStart);
    if (exchange.any((m) => m.outgoing) && exchange.any((m) => !m.outgoing)) {
      _connected.add(thread.contactId);
      onConnected?.call();
    }
  }

  void disconnect(String id) {
    if (!_connected.remove(id)) return;
    for (final timer in _replyTimers.remove(id) ?? <Timer>[]) {
      timer.cancel();
    }
    final thread = _threads[id];
    if (thread != null) thread.connectionStart = thread._messages.length;
    _changed();
  }

  void setNotifications(bool enabled) {
    notificationChoiceMade = true;
    notificationsEnabled = enabled;
    _changed();
  }

  Future<void> reset() async {
    for (final timers in _replyTimers.values) {
      for (final timer in timers) {
        timer.cancel();
      }
    }
    _replyTimers.clear();
    activeContactId = null;
    notificationChoiceMade = false;
    notificationsEnabled = false;
    _seed();
    _changed();
    await flush();
  }

  void _changed() {
    _revision++;
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(flush()),
    );
    _notify();
  }

  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!loaded || loadFailed || _savedRevision == _revision) return _queue;
    final snapshot = _encode();
    final revision = _revision;
    _queue = _queue.then((_) async {
      try {
        await _store?.write(snapshot);
        _savedRevision = revision;
        if (_savedRevision == _revision) error = null;
      } catch (_) {
        error = 'Chats could not be saved. Tap Retry.';
      }
      _notify();
    });
    return _queue;
  }

  String _encode() => jsonEncode({
    'version': 1,
    'threads': _threads.values.map((t) => t.toJson()).toList(),
    'connected': _connected.toList(),
    'notificationChoiceMade': notificationChoiceMade,
    'notificationsEnabled': notificationsEnabled,
  });

  void _decode(String source) {
    final data = jsonDecode(source) as Map<String, dynamic>;
    if (data['version'] != 1) throw const FormatException('Invalid chats');
    final threads = <String, DemoConversation>{};
    for (final item in data['threads'] as List) {
      final id = item['id'] as String;
      if (!demoPeople.containsKey(id) || threads.containsKey(id)) {
        throw const FormatException('Invalid contact');
      }
      final thread = DemoConversation(id);
      for (final message in item['messages'] as List) {
        final text = message['text'] as String;
        if (text.trim().isEmpty || text.length > 2000) {
          throw const FormatException('Invalid message');
        }
        thread._messages.add(
          DemoMessage(text, outgoing: message['outgoing'] as bool),
        );
      }
      thread.unread = item['unread'] as int;
      thread.connectionStart = item['connectionStart'] as int;
      thread.draft = item['draft'] as String;
      if (thread.unread < 0 ||
          thread.unread > thread._messages.where((m) => !m.outgoing).length ||
          thread.connectionStart < 0 ||
          thread.connectionStart > thread._messages.length ||
          thread.draft.length > 2000) {
        throw const FormatException('Invalid conversation');
      }
      threads[id] = thread;
    }
    final connected = (data['connected'] as List).cast<String>().toSet();
    if (connected.any((id) => !demoPeople.containsKey(id))) {
      throw const FormatException('Invalid connection');
    }
    final choice = data['notificationChoiceMade'] as bool;
    final enabled = data['notificationsEnabled'] as bool;
    _threads
      ..clear()
      ..addAll(threads);
    _connected
      ..clear()
      ..addAll(connected);
    notificationChoiceMade = choice;
    notificationsEnabled = enabled;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    for (final timers in _replyTimers.values) {
      for (final timer in timers) {
        timer.cancel();
      }
    }
    super.dispose();
  }
}
