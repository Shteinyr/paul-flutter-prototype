@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/live/invitation_actions.dart';

@JS('eval')
external JSAny? _eval(JSString code);

void _run(String code) => _eval(code.toJS);

void main() {
  setUp(
    () => _run('''
    globalThis.originalShare = Object.getOwnPropertyDescriptor(navigator, 'share');
    globalThis.originalClipboard = Object.getOwnPropertyDescriptor(navigator, 'clipboard');
    globalThis.sharedText = null;
    globalThis.copiedText = null;
  '''),
  );
  tearDown(
    () => _run('''
    for (const [key, descriptor] of [['share', originalShare], ['clipboard', originalClipboard]]) {
      if (descriptor) Object.defineProperty(navigator, key, descriptor);
      else delete navigator[key];
    }
    delete globalThis.sharedText;
    delete globalThis.copiedText;
    delete globalThis.originalShare;
    delete globalThis.originalClipboard;
  '''),
  );

  test(
    'browser adapter forwards exact invitation to clipboard and share',
    () async {
      _run('''
      Object.defineProperty(navigator, 'clipboard', {configurable: true, value: {
        writeText: text => { globalThis.copiedText = text; return Promise.resolve(); }
      }});
      Object.defineProperty(navigator, 'share', {configurable: true, value: data => {
        globalThis.sharedText = data.text;
        return Promise.resolve();
      }});
    ''');
      final actions = createInvitationActions();
      expect(actions.canShare, isTrue);
      const message =
          'Synthetic invitation\nhttps://paul.example/#invite=synthetic\ncode-1';
      expect(await actions.copy(message), InvitationActionResult.completed);
      expect(await actions.share(message), InvitationActionResult.completed);
      expect((_eval('copiedText'.toJS) as JSString).toDart, message);
      expect((_eval('sharedText'.toJS) as JSString).toDart, message);
    },
  );

  test(
    'browser rejection names preserve cancellation and permission outcomes',
    () async {
      final actions = createInvitationActions();
      for (final entry in {
        'AbortError': InvitationActionResult.cancelled,
        'NotAllowedError': InvitationActionResult.denied,
        'SecurityError': InvitationActionResult.denied,
        'InvalidStateError': InvitationActionResult.failed,
      }.entries) {
        _run('''
        Object.defineProperty(navigator, 'share', {configurable: true, value: () =>
          Promise.reject(new DOMException('Synthetic failure', '${entry.key}'))});
      ''');
        expect(await actions.share('synthetic'), entry.value);
      }
      _run('''
      Object.defineProperty(navigator, 'clipboard', {configurable: true, value: {
        writeText: () => Promise.reject(new DOMException('Synthetic denial', 'NotAllowedError'))
      }});
    ''');
      expect(await actions.copy('synthetic'), InvitationActionResult.denied);
    },
  );
}
