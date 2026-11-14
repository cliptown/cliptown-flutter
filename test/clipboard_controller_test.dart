import 'dart:async';
import 'dart:typed_data';

import 'package:cliptown_app/clipboard/clipboard_controller.dart';
import 'package:cliptown_app/clipboard/clipboard_service.dart';
import 'package:cliptown_app/history/capture_policy.dart';
import 'package:cliptown_app/history/clip_item.dart';
import 'package:cliptown_app/history/clip_repository.dart';
import 'package:cliptown_app/history/clipboard_snapshot.dart';
import 'package:cliptown_app/history/text_transform.dart';
import 'package:cliptown_app/src/clip_store.dart';
import 'package:cliptown_app/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ClipStore store;
  late MemoryClipClipboardService clipboard;
  late ClipboardController controller;

  setUp(() async {
    store = ClipStore(repository: MemoryClipRepository());
    await store.initialize();
    clipboard = MemoryClipClipboardService();
    controller = ClipboardController(
      store: store,
      service: clipboard,
      automaticCaptureSupported: true,
    );
  });

  tearDown(() => controller.dispose());

  test('automatic monitoring captures supported changes', () async {
    await controller.initialize();
    expect(controller.monitoring, isTrue);
    expect(controller.stateMachine.state.capture, AppCaptureState.monitoring);

    await clipboard.emit(
      ClipboardSnapshot.text(text: 'https://cliptown.example/feature'),
    );

    expect(store.clips.single.kind.name, 'link');
    expect(store.clips.single.text, 'https://cliptown.example/feature');
  });

  test('automatic monitoring indexes image bytes and file lists', () async {
    await controller.initialize();

    await clipboard.emit(
      ClipboardSnapshot.image(
        data: Uint8List.fromList(<int>[137, 80, 78, 71]),
        mimeType: 'image/png',
      ),
    );
    await clipboard.emit(
      ClipboardSnapshot.files(
        fileUris: const <String>[
          'file:///tmp/ClipTown%20contract.pdf',
          'file:///tmp/diagram.png',
        ],
      ),
    );

    expect(store.clips.map((item) => item.kind), contains(ClipKind.image));
    expect(store.clips.map((item) => item.kind), contains(ClipKind.files));
    expect(
      store.clips.singleWhere((item) => item.kind == ClipKind.files).fileUris,
      hasLength(2),
    );
  });

  test('pause visibly stops monitoring and rejects new changes', () async {
    await controller.initialize();
    await controller.setCaptureEnabled(false);

    expect(controller.monitoring, isFalse);
    expect(controller.stateMachine.state.captureRequested, isFalse);
    expect(controller.stateMachine.state.capture, AppCaptureState.disabled);
    await clipboard.emit(ClipboardSnapshot.text(text: 'not captured'));
    expect(store.clips, isEmpty);
  });

  test('manual capture works without hidden mobile monitoring', () async {
    controller.dispose();
    clipboard = MemoryClipClipboardService(
      current: ClipboardSnapshot.text(text: 'foreground capture'),
    );
    controller = ClipboardController(store: store, service: clipboard);

    await controller.initialize();
    expect(controller.monitoring, isFalse);
    final result = await controller.captureNow();

    expect(result.accepted, isTrue);
    expect(store.clips.single.text, 'foreground capture');
  });

  test('copy transformations write only transformed text', () async {
    final result = await store.addText('{"b":2,"a":1}');
    await controller.copy(result.item!, transform: TextTransform.prettyJson);

    expect(clipboard.lastWritten?.id, result.item!.id);
    expect(clipboard.lastTextOverride, '{\n  "b": 2,\n  "a": 1\n}');
  });

  test(
    'vault lock formally stops the desktop watcher before more capture',
    () async {
      await controller.initialize();
      expect(controller.monitoring, isTrue);

      final lock = controller.stateMachine.dispatch(AppEvent.lockRequested);
      expect(lock.accepted, isTrue);
      await controller.reconcileWithState();

      expect(controller.monitoring, isFalse);
      expect(controller.stateMachine.state.capture, AppCaptureState.disabled);
      await clipboard.emit(
        ClipboardSnapshot.text(text: 'must not be captured'),
      );
      expect(store.clips, isEmpty);
    },
  );

  test(
    'mobile background rejects manual capture without reading contents',
    () async {
      controller.dispose();
      final machine = AppStateMachine.localReady(
        AppRuntimeKind.mobile,
        captureRequested: true,
      );
      addTearDown(machine.dispose);
      final countingClipboard = _CountingClipboardService(
        current: ClipboardSnapshot.text(text: 'must remain unread'),
      );
      clipboard = countingClipboard;
      controller = ClipboardController(
        store: store,
        service: clipboard,
        stateMachine: machine,
      );

      final background = machine.dispatch(AppEvent.backgroundRequested);
      expect(background.accepted, isTrue);
      final result = await controller.captureNow();

      expect(result.accepted, isFalse);
      expect(result.rejectionReason, CaptureRejectionReason.paused);
      expect(machine.state.vault, AppVaultState.locked);
      expect(machine.state.capture, AppCaptureState.disabled);
      expect(countingClipboard.readCount, 0);
      expect(store.clips, isEmpty);
    },
  );

  test(
    'stale clipboard read completion cannot persist after backgrounding',
    () async {
      controller.dispose();
      final machine = AppStateMachine.localReady(
        AppRuntimeKind.mobile,
        captureRequested: true,
      );
      addTearDown(machine.dispose);
      final deferredClipboard = _DeferredReadClipboardService();
      clipboard = deferredClipboard;
      controller = ClipboardController(
        store: store,
        service: clipboard,
        stateMachine: machine,
      );

      final capture = controller.captureNow();
      await expectLater(deferredClipboard.readStarted, completes);
      expect(machine.dispatch(AppEvent.backgroundRequested).accepted, isTrue);
      deferredClipboard.completeRead(
        ClipboardSnapshot.text(text: 'stale completion'),
      );

      final result = await capture;
      expect(result.accepted, isFalse);
      expect(result.rejectionReason, CaptureRejectionReason.paused);
      expect(store.clips, isEmpty);
    },
  );
}

class _CountingClipboardService extends MemoryClipClipboardService {
  _CountingClipboardService({super.current});

  int readCount = 0;

  @override
  Future<ClipboardSnapshot?> read() async {
    readCount += 1;
    return super.read();
  }
}

class _DeferredReadClipboardService extends MemoryClipClipboardService {
  final Completer<void> _readStarted = Completer<void>();
  final Completer<ClipboardSnapshot?> _readResult =
      Completer<ClipboardSnapshot?>();

  Future<void> get readStarted => _readStarted.future;

  void completeRead(ClipboardSnapshot snapshot) =>
      _readResult.complete(snapshot);

  @override
  Future<ClipboardSnapshot?> read() {
    if (!_readStarted.isCompleted) _readStarted.complete();
    return _readResult.future;
  }
}
