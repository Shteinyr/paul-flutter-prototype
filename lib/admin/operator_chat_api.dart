import 'dart:async';
import 'dart:typed_data';

import '../live/chat_api.dart';
import '../live/live_api.dart';
import 'admin_api.dart';

/// The authenticated operator stays the actor. Only server-authorized commands
/// select this managed sender, without switching Auth or exposing service keys.
class OperatorChatApi implements ChatRepository {
  OperatorChatApi(this.admin, this.profileId);
  final SupabaseAdminApi admin;
  final String profileId;
  final _accessChanges = StreamController<String?>.broadcast();
  bool _denied = false;
  bool disabled = false;
  @override
  String? get currentUserId =>
      _denied ? null : admin.client.auth.currentUser?.id;
  @override
  Stream<String?> get identityChanges => Stream<String?>.multi((events) {
    final auth = admin.client.auth.onAuthStateChange.listen(
      (event) => events.add(_denied ? null : event.session?.user.id),
      onError: events.addError,
    );
    final access = _accessChanges.stream.listen(
      events.add,
      onError: events.addError,
    );
    events.onCancel = () async {
      await auth.cancel();
      await access.cancel();
    };
  });

  Future<Map<String, dynamic>> _call(
    String action, [
    Map<String, dynamic> fields = const {},
  ]) async {
    if (currentUserId != admin.userId) {
      throw const ChatException('sign_in_required');
    }
    try {
      return await admin.request({
        'action': action,
        'profile_id': profileId,
        ...fields,
      });
    } on AdminException catch (error) {
      if (error.code == 'admin_forbidden' ||
          error.code == 'managed_profile_forbidden' ||
          error.code == 'sign_in_required') {
        _denied = true;
        if (!_accessChanges.isClosed) _accessChanges.add(null);
      }
      throw ChatException(error.code);
    }
  }

  @override
  Future<List<ChatSummary>> list() async {
    final data = await _call('inbox');
    disabled = data['profile_disabled'] == true;
    return (data['conversations'] as List)
        .map(
          (item) =>
              ChatSummary.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
  }

  @override
  Future<String> open(String peerId) async =>
      throw const ChatException('conversation_forbidden');

  Future<Uint8List?> photo(ChatPeer peer) async {
    if (currentUserId != admin.userId) {
      throw const ChatException('sign_in_required');
    }
    if (peer.deletedAt != null) return null;
    final path = peer.avatarPath;
    final Uint8List? bytes;
    if (path == null) {
      // The operator inbox intentionally omits avatar_path. Resolve the peer
      // through the same authorized profile read used by global search.
      final api = LiveApi(admin.client);
      final member = await api.member(peer.id);
      if (currentUserId != admin.userId) {
        throw const ChatException('sign_in_required');
      }
      bytes = await api.photo(member);
    } else {
      bytes = await admin.client.storage.from('avatars').download(path);
    }
    if (currentUserId != admin.userId) {
      throw const ChatException('sign_in_required');
    }
    return bytes;
  }

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
            (item) =>
                ChatMessage.fromJson(Map<String, dynamic>.from(item as Map)),
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
  Future<void> read(String conversationId, int through) async {
    await _call('read', {
      'conversation_id': conversationId,
      'through_seq': through,
    });
  }

  @override
  Future<void> disconnect(String peerId, String clientOperationId) async =>
      throw const ChatException('conversation_forbidden');
  @override
  Stream<String> watch() => SupabaseChatApi(
    admin.client,
    admin.userId,
    inboxPrefix: 'admin:user',
  ).watch();

  Future<void> dispose() => _accessChanges.close();
}
