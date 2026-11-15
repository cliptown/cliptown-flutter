import 'dart:async';

import 'package:cliptown_app/history/cache/semantic_search_controller.dart';
import 'package:cliptown_app/history/clip_item.dart';
import 'package:cliptown_app/history/clip_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('debounces typing and uses only the final query', () async {
    final repository = _QueuedSemanticRepository();
    var notifications = 0;
    final controller = SemanticSearchController(
      repository: repository,
      onChanged: () => notifications += 1,
    )..activate();

    controller.setQuery('buy');
    controller.setQuery('buy shoes');
    await Future<void>.delayed(const Duration(milliseconds: 220));

    expect(repository.queries, <String>['buy shoes']);
    repository.resolve('buy shoes', <String>['shoe-clip', 'other-clip']);
    await Future<void>.delayed(Duration.zero);
    expect(controller.rankOf('shoe-clip'), 0);
    expect(controller.rankOf('other-clip'), 1);
    expect(notifications, 1);
    controller.dispose();
    await repository.close();
  });

  test('late results cannot overwrite the latest search', () async {
    final repository = _QueuedSemanticRepository();
    final controller = SemanticSearchController(
      repository: repository,
      onChanged: () {},
      debounce: const Duration(milliseconds: 1),
    )..activate();

    controller.setQuery('alpha');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    controller.setQuery('beta');
    await Future<void>.delayed(const Duration(milliseconds: 10));

    repository.resolve('beta', <String>['new']);
    await Future<void>.delayed(Duration.zero);
    repository.resolve('alpha', <String>['old']);
    await Future<void>.delayed(Duration.zero);

    expect(controller.matches('old'), isFalse);
    expect(controller.matches('new'), isTrue);
    controller.dispose();
    await repository.close();
  });

  test('coalesces index updates during one in-flight semantic search', () async {
    final repository = _QueuedSemanticRepository();
    final controller = SemanticSearchController(
      repository: repository,
      onChanged: () {},
      refreshInterval: Duration.zero,
    )..activate();

    controller.setQuery('search term');
    repository.notifyIndex();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repository.queries, <String>['search term']);

    repository.notifyIndex();
    repository.notifyIndex();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repository.queries, hasLength(1));

    repository.resolve('search term', <String>['first']);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(repository.queries, hasLength(2));
    repository.resolve('search term', <String>['second']);
    await Future<void>.delayed(Duration.zero);
    expect(controller.matches('second'), isTrue);
    controller.dispose();
    await repository.close();
  });

  test('index updates refresh a query without additional typing', () async {
    final repository = _QueuedSemanticRepository();
    final controller = SemanticSearchController(
      repository: repository,
      onChanged: () {},
      refreshInterval: Duration.zero,
    )..activate();

    controller.setQuery('semantic text');
    repository.notifyIndex();
    await Future<void>.delayed(Duration.zero);
    expect(repository.queries, <String>['semantic text']);

    repository.resolve('semantic text', <String>['match']);
    await Future<void>.delayed(Duration.zero);
    expect(controller.matches('match'), isTrue);

    controller.dispose();
    await repository.close();
  });
}

final class _QueuedSemanticRepository
    implements
        ClipRepository,
        SemanticClipRepository,
        SemanticClipRepositoryUpdates {
  final Map<String, Completer<List<String>>> _calls =
      <String, Completer<List<String>>>{};
  final StreamController<void> _updates = StreamController<void>.broadcast();
  final List<String> queries = <String>[];

  @override
  Stream<void> get indexUpdates => _updates.stream;

  @override
  Future<List<String>> semanticSearchIds(String query, {int limit = 20}) {
    queries.add(query);
    final call = Completer<List<String>>();
    _calls[query] = call;
    return call.future;
  }

  void resolve(String query, List<String> result) {
    final call = _calls[query];
    if (call == null) throw StateError('query not started');
    call.complete(result);
  }

  void notifyIndex() => _updates.add(null);

  Future<void> close() => _updates.close();

  @override
  Future<List<ClipItem>> load() async => const <ClipItem>[];

  @override
  Future<void> save(List<ClipItem> clips) async {}

  @override
  Future<void> clear() async {}
}
