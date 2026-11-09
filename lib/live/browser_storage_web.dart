import 'package:web/web.dart' as web;

String? readSessionValue(String key) => web.window.sessionStorage.getItem(key);
void writeSessionValue(String key, String value) =>
    web.window.sessionStorage.setItem(key, value);
void removeSessionValue(String key) =>
    web.window.sessionStorage.removeItem(key);

void clearInviteFromAddress() {
  final uri = Uri.parse(web.window.location.href);
  if (uri.fragment.startsWith('invite=')) {
    web.window.history.replaceState(
      null,
      '',
      uri.replace(fragment: '').toString(),
    );
  }
}
