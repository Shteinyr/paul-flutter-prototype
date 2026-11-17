import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/app.dart' show ProfileAvatar;
import 'package:paul_demo/live/live_api.dart';
import 'package:paul_demo/live/member_avatar.dart';
import 'package:paul_demo/profile/user_profile.dart';

class _Api extends Fake implements LiveApi {
  String path = 'v1';
  int reads = 0;
  final ready = <String, Uint8List>{};
  Completer<Uint8List?>? pending;
  @override
  MemberProfile? cachedMember(String id) => MemberProfile(
    id: id,
    profile: UserProfile.empty,
    contactCount: 1,
    avatarPath: path,
  );
  @override
  Uint8List? cachedPhoto(String id, String? path) => ready[path];
  @override
  Future<MemberProfile> member(String id) async => cachedMember(id)!;
  @override
  Future<Uint8List?> photo(MemberProfile profile) {
    reads++;
    final version = profile.avatarPath!;
    final future = pending?.future ?? Future.value(ready[version]);
    return future.then((bytes) {
      if (bytes != null) ready[version] = bytes;
      return bytes;
    });
  }
}

void main() {
  testWidgets(
    'an invalidated old download cannot mark the new version as loaded',
    (tester) async {
      final api = _Api();
      final bytes = (await rootBundle.load(
        'assets/people/paul-galda.png',
      )).buffer.asUint8List();
      final old = Completer<Uint8List?>();
      api.pending = old;
      Widget view() => MaterialApp(
        home: MemberAvatar(api: api, profileId: 'peer', resolveProfile: true),
      );
      await tester.pumpWidget(view());
      await tester.pump();
      api.path = 'v2';
      api.pending = null;
      api.ready['v2'] = bytes;
      old.complete(null);
      await tester.pump();
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(api.reads, 2);
      expect(
        tester.widget<ProfileAvatar>(find.byType(ProfileAvatar)).photo,
        same(bytes),
      );
    },
  );

  testWidgets(
    'search portrait follows a changed resolved path without showing the old photo',
    (tester) async {
      final api = _Api();
      final first = (await rootBundle.load(
        'assets/people/julia-robinson.png',
      )).buffer.asUint8List();
      final second = (await rootBundle.load(
        'assets/people/paul-galda.png',
      )).buffer.asUint8List();
      api.ready['v1'] = first;
      Widget view() => MaterialApp(
        home: MemberAvatar(api: api, profileId: 'peer', resolveProfile: true),
      );
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(
        tester.widget<ProfileAvatar>(find.byType(ProfileAvatar)).photo,
        same(first),
      );
      api.path = 'v2';
      api.ready.remove('v1');
      final replacement = Completer<Uint8List?>();
      api.pending = replacement;
      await tester.pumpWidget(view());
      expect(
        tester.widget<ProfileAvatar>(find.byType(ProfileAvatar)).photo,
        isNull,
      );
      replacement.complete(second);
      await tester.pumpAndSettle();
      expect(
        tester.widget<ProfileAvatar>(find.byType(ProfileAvatar)).photo,
        same(second),
      );
      expect(api.reads, 2);
    },
  );
}
