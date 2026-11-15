import '../../live/chat_controller.dart';

Future<void> initializePlatformStorage() async {}
ChatStateStore createChatStateStore(String accountId) =>
    SessionChatStateStore();

void deleteAccountStorage(String accountId) {}
