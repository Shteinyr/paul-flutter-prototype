import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/search/skill_search_api.dart';
import 'package:paul_demo/search/skill_search_controller.dart';
import 'package:paul_demo/search/skill_search_view.dart';
import 'profile_name_search_test.dart' show NameRepository;

void main() {
  const longName =
      'Julia Robinson with an exceptionally long full display name';
  const one = MutualContact(
    id: 'julia',
    name: longName,
    occupation: 'Designer',
  );
  const two = MutualContact(
    id: 'maya',
    name: 'Maya Chen',
    occupation: 'Designer',
  );
  const three = MutualContact(
    id: 'victoria',
    name: 'Victoria Fox',
    occupation: 'Designer',
  );
  const four = MutualContact(
    id: 'extra',
    name: 'Not shown',
    occupation: 'Designer',
  );
  test('legacy and guest result constructors have no graph data', () {
    const hit = SkillSearchHit(
      id: 'guest',
      name: 'Paul',
      occupation: 'Analyst',
      matchedKinds: {},
    );
    expect(hit.mutualContacts, isEmpty);
    expect(hit.mutualContactCount, 0);
    expect(
      const SkillSearchException('session_revoked').toString(),
      contains('sign in'),
    );
  });
  for (final width in [320.0, 390.0]) {
    for (final count in [0, 1, 5]) {
      testWidgets(
        'attribution count$count fits width$width and retains full semantics',
        (tester) async {
          tester.view.physicalSize = Size(width, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final repo = NameRepository();
          final search = SkillSearchController(
            repo,
            localSuggest: (_) async => [],
          );
          addTearDown(() async {
            search.dispose();
            await repo.identities.close();
          });
          repo.finding = (q, c) async => SkillSearchPage(
            query: q,
            kind: SkillSearchKind.all,
            results: [
              SkillSearchHit(
                id: 'paul',
                name: 'Alex Morgan',
                occupation: 'Business Analyst',
                matchedKinds: {SkillSearchKind.offering},
                mutualContacts: count == 1
                    ? [one]
                    : count == 0
                    ? []
                    : [one, two, three, four],
                mutualContactCount: count,
              ),
            ],
          );
          final handle = tester.ensureSemantics();
          try {
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: SkillSearchView(
                    controller: search,
                    contacts: const SizedBox(),
                    onOpen: (_) async {},
                    avatarFor: (_) => const CircleAvatar(radius: 32.5),
                  ),
                ),
              ),
            );
            await search.selectName('Paul');
            await tester.pumpAndSettle();
            if (count == 0) {
              expect(
                find.byKey(const ValueKey('mutual-contact-paul')),
                findsNothing,
              );
            } else {
              final footer = find.byKey(const ValueKey('mutual-contact-paul'));
              expect(footer, findsOneWidget);
              final text = tester.widget<Text>(footer);
              expect(text.maxLines, 1);
              expect(text.overflow, TextOverflow.ellipsis);
              expect(
                tester.getRect(footer).right,
                lessThanOrEqualTo(width - 37),
              );
              final label = count == 1
                  ? '$longName’s contact'
                  : 'Mutual contacts (5): $longName, Maya Chen, Victoria Fox';
              expect(
                find.bySemanticsLabel(RegExp(RegExp.escape(label))),
                findsOneWidget,
              );
              expect(
                tester.widget<Tooltip>(find.byType(Tooltip).last).message,
                isNot(contains('Not shown')),
              );
            }
            expect(tester.takeException(), isNull);
          } finally {
            handle.dispose();
          }
        },
      );
    }
  }
}
