import 'dart:async';

import 'package:rxdart/rxdart.dart';

import 'package:cliptown_app/cliptown_app.dart';
import 'package:cliptown_app/history/clip_item.dart';
import 'package:cliptown_app/history/clip_repository.dart';
import 'package:cliptown_app/src/clip_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  testWidgets('search bar shows model progress and a working retry control', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _ProgressRepository();
    final store = ClipStore(repository: repository);
    await store.initialize();
    await tester.pumpWidget(ClipTownApp(store: store));
    await tester.pumpAndSettle();

    repository.publish(
      const SemanticIndexProgress(
        phase: SemanticIndexPhase.downloading,
        indexed: 0,
        total: 2,
        downloadPercent: 40,
      ),
    );
    await tester.pump();
    expect(
      find.textContaining('Downloading MiniLM model: 40%'),
      findsOneWidget,
    );

    repository.publish(
      const SemanticIndexProgress(
        phase: SemanticIndexPhase.unavailable,
        indexed: 0,
        total: 2,
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const Key('retry-local-semantic-search')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('retry-local-semantic-search')));
    await tester.pumpAndSettle();

    expect(repository.retries.value, 1);
    expect(
      find.textContaining('Meaning search ready (2 clips)'),
      findsOneWidget,
    );
    expect(find.text('Deploy command'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
    await repository.close();
  });
}

final class _ProgressRepository
    implements ClipRepository, SemanticIndexProgressSource {
  final BehaviorSubject<SemanticIndexProgress> _events =
      BehaviorSubject<SemanticIndexProgress>.seeded(
        const SemanticIndexProgress(
          phase: SemanticIndexPhase.preparing,
          indexed: 0,
          total: 2,
        ),
      );
  final ValueNotifier<int> retries = ValueNotifier<int>(0);

  @override
  SemanticIndexProgress get indexProgress => _events.value;

  @override
  Stream<SemanticIndexProgress> get indexProgressUpdates => _events.stream;

  void publish(SemanticIndexProgress status) {
    _events.add(status);
  }

  @override
  Future<void> retrySemanticIndex() async {
    retries.value += 1;
    publish(
      const SemanticIndexProgress(
        phase: SemanticIndexPhase.ready,
        indexed: 2,
        total: 2,
      ),
    );
  }

  Future<void> close() => _events.close();

  @override
  Future<List<ClipItem>> load() async => demoClipItems();

  @override
  Future<void> save(List<ClipItem> clips) async {}

  @override
  Future<void> clear() async {}
}
