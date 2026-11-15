import '../../live/browser_storage.dart';

class AccountValueStore {
  AccountValueStore(this.accountId);
  final String accountId;
  String _key(String key) => 'paul.account.$accountId.$key';
  String? read(String key) => readSessionValue(_key(key));
  void write(String key, String value) => writeSessionValue(_key(key), value);
  bool compareAndSwap(String key, String? expected, String? value) {
    if (read(key) != expected) return false;
    if (value == null) {
      removeSessionValue(_key(key));
    } else {
      write(key, value);
    }
    return true;
  }
}
