import 'dart:async';
import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';

String newChatOperationId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class ChatException implements Exception {
  const ChatException(this.code);
  final String code;
  @override
  String toString() => switch (code) {
    'sign_in_required' => 'Please sign in again to continue.',
    'conversation_forbidden' || 'membership_required' =>
      'This conversation is unavailable for your account.',
    'invalid_message' => 'Enter a message with up to 2000 characters.',
    'message_id_conflict' =>
      'This message was already sent with different text.',
    'rate_limited' => 'Too many attempts. Wait a minute and try again.',
    _ => 'Could not update your chat. Check your connection and retry.',
  };
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.sequence,
    required this.senderId,
    String? actorUserId,
    required this.clientMessageId,
    required this.text,
    required this.createdAt,
  }) : actorUserId = actorUserId ?? senderId;
  final String id;
  final String conversationId;
  final int sequence;
  final String senderId;
  final String actorUserId;
  final String clientMessageId;
  final String text;
  final DateTime createdAt;
  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String,
    conversationId: json['conversation_id'] as String,
    sequence: json['seq'] as int,
    senderId: json['sender_profile_id'] as String,
    actorUserId: json['actor_user_id'] as String?,
    clientMessageId: json['client_message_id'] as String,
    text: json['text'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
  );
}

class ChatPeer {
  const ChatPeer({
    required this.id,
    required this.name,
    required this.occupation,
    this.avatarPath,
  });
  final String id;
  final String name;
  final String occupation;
  final String? avatarPath;
  factory ChatPeer.fromJson(Map<String, dynamic> json) => ChatPeer(
    id: json['id'] as String,
    name: json['name'] as String,
    occupation: json['occupation'] as String,
    avatarPath: json['avatar_path'] as String?,
  );
}

class ChatSummary {
  const ChatSummary({
    required this.id,
    required this.peer,
    required this.lastSequence,
    required this.lastReadSequence,
    required this.unread,
    this.lastMessage,
  });
  final String id;
  final ChatPeer peer;
  final int lastSequence;
  final int lastReadSequence;
  final int unread;
  final ChatMessage? lastMessage;
  factory ChatSummary.fromJson(Map<String, dynamic> json) => ChatSummary(
    id: json['id'] as String,
    peer: ChatPeer.fromJson(Map<String, dynamic>.from(json['peer'] as Map)),
    lastSequence: json['last_message_seq'] as int,
    lastReadSequence: json['last_read_seq'] as int,
    unread: json['unread_count'] as int,
    lastMessage: json['last_message'] == null
        ? null
        : ChatMessage.fromJson(
            Map<String, dynamic>.from(json['last_message'] as Map),
          ),
  );
}

class ChatHistory {
  const ChatHistory(this.messages, this.lastSequence);
  final List<ChatMessage> messages;
  final int lastSequence;
}

class ChatAcknowledgement {
  const ChatAcknowledgement(
    this.message, {
    required this.replayed,
    required this.connected,
  });
  final ChatMessage message;
  final bool replayed;
  final bool connected;
}

abstract interface class ChatRepository {
  String? get currentUserId;
  Stream<String?> get identityChanges;
  Stream<String> watch();
  Future<List<ChatSummary>> list();
  Future<String> open(String peerId);
  Future<ChatHistory> history(String conversationId, {int? before, int? after});
  Future<ChatAcknowledgement> send(
    String conversationId,
    String clientMessageId,
    String text,
  );
  Future<void> read(String conversationId, int through);
  Future<void> disconnect(String peerId, String clientOperationId);
}

class SupabaseChatApi implements ChatRepository {
  SupabaseChatApi(this.client, this.userId, {this.inboxPrefix = 'chat:user'});
  final SupabaseClient client;
  final String userId;
  final String inboxPrefix;
  @override
  String? get currentUserId => client.auth.currentUser?.id;
  @override
  Stream<String?> get identityChanges =>
      client.auth.onAuthStateChange.map((event) => event.session?.user.id);

  void _checkIdentity() {
    if (currentUserId != userId) throw const ChatException('sign_in_required');
  }

  Future<Map<String, dynamic>> _call(
    String action, [
    Map<String, dynamic> fields = const {},
  ]) async {
    _checkIdentity();
    final initiatingToken = client.auth.currentSession?.accessToken;
    if (initiatingToken == null) throw const ChatException('sign_in_required');
    try {
      final response = await client.functions
          .invoke(
            'chat',
            headers: {'Authorization': 'Bearer $initiatingToken'},
            body: {'action': action, ...fields},
          )
          .timeout(const Duration(seconds: 25));
      _checkIdentity();
      return Map<String, dynamic>.from(response.data as Map);
    } on FunctionException catch (error) {
      _checkIdentity();
      final details = error.details;
      throw ChatException(
        details is Map
            ? details['code'] as String? ?? 'server_unavailable'
            : 'server_unavailable',
      );
    }
  }

  @override
  Future<List<ChatSummary>> list() async =>
      ((await _call('list'))['conversations'] as List)
          .map(
            (value) =>
                ChatSummary.fromJson(Map<String, dynamic>.from(value as Map)),
          )
          .toList();
  @override
  Future<String> open(String peerId) async =>
      (await _call('open', {'peer_id': peerId}))['id'] as String;
  @override
  Future<ChatHistory> history(
    String conversationId, {
    int? before,
    int? after,
  }) async {
    final data = await _call('history', {
      'conversation_id': conversationId,
      'before_seq': ?before,
      'after_seq': ?after,
      'limit': 100,
    });
    return ChatHistory(
      (data['messages'] as List)
          .map(
            (value) =>
                ChatMessage.fromJson(Map<String, dynamic>.from(value as Map)),
          )
          .toList(),
      data['last_message_seq'] as int,
    );
  }

  @override
  Future<ChatAcknowledgement> send(
    String conversationId,
    String clientMessageId,
    String text,
  ) async {
    final data = await _call('send', {
      'conversation_id': conversationId,
      'client_message_id': clientMessageId,
      'text': text,
    });
    return ChatAcknowledgement(
      ChatMessage.fromJson(Map<String, dynamic>.from(data['message'] as Map)),
      replayed: data['replayed'] as bool,
      connected: data['connected'] as bool,
    );
  }

  @override
  Future<void> read(String conversationId, int through) async => _call('read', {
    'conversation_id': conversationId,
    'through_seq': through,
  });
  @override
  Future<void> disconnect(String peerId, String clientOperationId) async =>
      _call('disconnect', {
        'peer_id': peerId,
        'client_operation_id': clientOperationId,
      });

  @override
  Stream<String> watch() {
    RealtimeChannel? channel;
    var cancelled = false;
    late final StreamController<String> events;
    Future<void> start() async {
      try {
        _checkIdentity();
        await client.realtime.setAuth(client.auth.currentSession?.accessToken);
        if (cancelled) return;
        _checkIdentity();
        final value = client.channel(
          '$inboxPrefix:$userId',
          opts: const RealtimeChannelConfig(private: true),
        );
        channel = value;
        value
            .onBroadcast(
              event: 'changed',
              callback: (payload) {
                if (!cancelled && currentUserId == userId) {
                  events.add('changed');
                }
              },
            )
            .subscribe((status, error) {
              if (cancelled || currentUserId != userId) return;
              if (status == RealtimeSubscribeStatus.subscribed) {
                events.add('subscribed');
              }
              if (status == RealtimeSubscribeStatus.channelError ||
                  status == RealtimeSubscribeStatus.timedOut) {
                events.addError(const ChatException('realtime_unavailable'));
              }
            });
      } catch (_) {
        if (!cancelled) {
          events.addError(const ChatException('realtime_unavailable'));
        }
      }
    }

    events = StreamController<String>(
      onListen: start,
      onCancel: () async {
        cancelled = true;
        final value = channel;
        if (value != null) await client.removeChannel(value);
      },
    );
    return events.stream;
  }
}
