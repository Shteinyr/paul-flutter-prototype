import 'package:paul_demo/live/chat_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Auth-focused host tests keep their chat transport local and silent.
class QuietChatRepository implements ChatRepository {
  QuietChatRepository(this.client);
  final SupabaseClient client;
  @override
  String? get currentUserId => client.auth.currentUser?.id;
  @override
  Stream<String?> get identityChanges =>
      client.auth.onAuthStateChange.map((event) => event.session?.user.id);
  @override
  Stream<String> watch() => const Stream.empty();
  @override
  Future<List<ChatSummary>> list() async => [];
  @override
  Future<String> open(String peerId) async =>
      throw StateError('Unexpected chat action');
  @override
  Future<ChatHistory> history(String id, {int? before, int? after}) async =>
      const ChatHistory([], 0);
  @override
  Future<ChatAcknowledgement> send(
    String id,
    String clientId,
    String text,
  ) async => throw StateError('Unexpected chat action');
  @override
  Future<void> read(String id, int through) async {}
  @override
  Future<void> disconnect(String peerId, String operationId) async =>
      throw StateError('Unexpected chat action');
}
