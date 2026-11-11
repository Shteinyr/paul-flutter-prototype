import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/skills/skill_catalogue.dart';
import 'package:paul_demo/skills/skill_suggestions.dart';

class _CatalogueBundle extends CachingAssetBundle {
  int reads = 0;
  bool fail = false;
  Completer<void>? pending;

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    reads++;
    await pending?.future;
    if (fail) throw StateError('Asset unavailable');
    return jsonEncode({
      'entries': [
        ['1', 'Marketing'],
        ['2', 'Digital Marketing'],
        ['3', 'MARKETING'],
        ['4', 'A' * 65],
      ],
    });
  }

  @override
  Future<ByteData> load(String key) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'catalogue normalizes keys, deduplicates and preserves distinct labels',
    () async {
      final bundle = _CatalogueBundle();
      final catalogue = SkillCatalogue(bundle: bundle);
      expect(await catalogue.suggest('  '), isEmpty);
      expect(bundle.reads, 0);
      final items = await catalogue.suggest('  MAR\u00a0 ');
      expect(items.map((item) => item.label), [
        'Marketing',
        'Digital Marketing',
      ]);
      expect(items.map((item) => item.key), ['marketing', 'digital marketing']);
      expect(await catalogue.suggest('A' * 65), isEmpty);
      expect(bundle.reads, 1);
      final merged = mergeSkillSuggestions([
        const SkillSuggestion(key: 'marketing', label: 'Legacy Marketing'),
        ...items,
        const SkillSuggestion(key: 'local marketing', label: 'Local Marketing'),
      ], 'marketing');
      expect(merged.first.label, 'Legacy Marketing');
      expect(merged.length, 3);
    },
  );

  test(
    'bundled catalogue has the pinned English source and usable common skills',
    () async {
      final raw = jsonDecode(
        await rootBundle.loadString('assets/skills/esco_en.json'),
      ) as Map;
      expect(raw['version'], 'v1.2.1');
      expect(raw['language'], 'en');
      expect((raw['entries'] as List).length, 13939);
      expect(raw['attribution'], contains('European Commission'));
      final items = await SkillCatalogue.shared.suggest('marketing');
      expect(items, isNotEmpty);
      expect(items.first.key, startsWith('marketing'));
    },
  );

  test(
    'common skills and services precede incidental word fragments',
    () async {
      final catalogue = SkillCatalogue.shared;
      for (final label in [
        'Flutter',
        'Dart',
        'Python',
        'React',
        'UX',
        'Marketing',
        'Digital Marketing',
        'Design',
        'Dog Walking',
        'Cleaning',
        'Plumbing',
      ]) {
        expect((await catalogue.suggest(label)).first.label, label);
      }
      final react = await catalogue.suggest('rea', limit: 3);
      expect(
        react.map((item) => item.label),
        containsAll(['React', 'React Native']),
      );
      final ux = await catalogue.suggest('ux');
      expect(ux.map((item) => item.label), containsAll(['UX', 'UX Research']));
      expect(ux.any((item) => item.key.contains('flux')), isFalse);
      expect((await catalogue.suggest('desing')), isEmpty);
      expect((await catalogue.suggest('My own service')), isEmpty);
      final marketing = await catalogue.suggest('marketing');
      expect(
        marketing.map((item) => item.key),
        containsAll(['marketing', 'digital marketing']),
      );
    },
  );

  testWidgets('suggestions support selection, free input and failure retry', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    final bundle = _CatalogueBundle()..fail = true;
    final catalogue = SkillCatalogue(bundle: bundle);
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextField(controller: controller, focusNode: focus),
              SkillSuggestions(
                controller: controller,
                focusNode: focus,
                selected: const [],
                catalogue: catalogue,
                onSelected: (value) => selected = value,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'mar');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('Could not load suggestions. Retry'), findsOneWidget);
    expect(controller.text, 'mar');
    bundle.fail = false;
    await tester.tap(find.text('Could not load suggestions. Retry'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('catalogue-marketing')));
    await tester.pumpAndSettle();
    expect(selected, 'Marketing');
    await tester.enterText(find.byType(TextField), 'My own service');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(controller.text, 'My own service');
    expect(find.byKey(const ValueKey('catalogue-marketing')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    focus.dispose();
  });

  testWidgets('late catalogue completion cannot show after field disposal', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    final gate = Completer<void>();
    final bundle = _CatalogueBundle()..pending = gate;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextField(controller: controller, focusNode: focus),
              SkillSuggestions(
                controller: controller,
                focusNode: focus,
                selected: const [],
                catalogue: SkillCatalogue(bundle: bundle),
                onSelected: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'mar');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(const SizedBox.shrink());
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    controller.dispose();
    focus.dispose();
  });
}
