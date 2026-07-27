import 'package:cliptown_app/src/clip_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pinned clips sort first and can be filtered', () {
    final store = ClipStore();
    expect(store.visibleClips.first.id, 'deploy-command');

    store.setPinnedOnly(true);
    expect(store.visibleClips.map((clip) => clip.id), <String>['deploy-command']);

    store.togglePinned('design-reference');
    expect(
      store.visibleClips.map((clip) => clip.id).toSet(),
      <String>{'deploy-command', 'design-reference'},
    );
  });

  test('search covers title, detail, and kind', () {
    final store = ClipStore();
    store.setQuery('image');
    expect(store.visibleClips.single.id, 'design-reference');

    store.setQuery('master key');
    expect(store.visibleClips.single.id, 'security-notes');
  });

  test('unknown pin target does not notify or mutate', () {
    final store = ClipStore();
    final before = store.visibleClips.map((clip) => clip.id).toList();
    store.togglePinned('missing');
    expect(store.visibleClips.map((clip) => clip.id), before);
  });
}
