import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clipboard_watcher/clipboard_watcher.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../history/clip_item.dart';
import '../history/clipboard_snapshot.dart';

typedef ClipboardSnapshotHandler = Future<void> Function(
  ClipboardSnapshot snapshot,
);

abstract interface class ClipClipboardService {
  bool get monitoring;

  Future<void> start(ClipboardSnapshotHandler onSnapshot);

  Future<void> stop();

  Future<ClipboardSnapshot?> read();

  Future<void> write(ClipItem item, {String? textOverride});
}

class SystemClipClipboardService
    with ClipboardListener
    implements ClipClipboardService {
  SystemClipClipboardService({
    this.maxBinaryBytes = 8 * 1024 * 1024,
    this.reconciliationInterval = const Duration(milliseconds: 500),
  });

  final int maxBinaryBytes;
  final Duration reconciliationInterval;
  ClipboardSnapshotHandler? _onSnapshot;
  bool _monitoring = false;
  bool _insideHandler = false;
  bool _readInFlight = false;
  String? _suppressedFingerprint;
  String? _lastObservedFingerprint;
  Timer? _reconciliationTimer;
  Future<void> _callbackTail = Future<void>.value();

  @override
  bool get monitoring => _monitoring;

  @override
  Future<void> start(ClipboardSnapshotHandler onSnapshot) async {
    _onSnapshot = onSnapshot;
    if (_monitoring) return;
    clipboardWatcher.addListener(this);
    try {
      await clipboardWatcher.start();
      _monitoring = true;
      try {
        _lastObservedFingerprint = (await read())?.fingerprintMaterial;
      } on Object {
        // The watcher remains useful when the clipboard is temporarily locked.
      }
      // Native change notifications remain the fast path. The reconciliation
      // poll closes platform/plugin gaps such as clipboard_watcher 0.3.0
      // observing X11 PRIMARY while applications write CLIPBOARD on Linux.
      _reconciliationTimer = Timer.periodic(
        reconciliationInterval,
        (_) => _scheduleRead(),
      );
    } on Object {
      clipboardWatcher.removeListener(this);
      _onSnapshot = null;
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    if (!_monitoring) {
      _onSnapshot = null;
      return;
    }
    _monitoring = false;
    _reconciliationTimer?.cancel();
    _reconciliationTimer = null;
    clipboardWatcher.removeListener(this);
    _onSnapshot = null;
    await clipboardWatcher.stop();
    // A fail-closed handler may stop monitoring while it is itself executing.
    // Awaiting its own tail would deadlock; external callers still wait for an
    // in-flight read/handler to finish.
    if (!_insideHandler) await _callbackTail;
  }

  @override
  void onClipboardChanged() {
    _scheduleRead();
  }

  void _scheduleRead() {
    if (!_monitoring || _readInFlight) return;
    _readInFlight = true;
    _callbackTail = _callbackTail
        .then((_) async {
          final handler = _onSnapshot;
          if (!_monitoring || handler == null) return;
          final snapshot = await read();
          if (!_monitoring) return;
          if (snapshot == null) {
            _lastObservedFingerprint = null;
            return;
          }
          final fingerprint = snapshot.fingerprintMaterial;
          if (_lastObservedFingerprint == fingerprint) return;
          _lastObservedFingerprint = fingerprint;
          if (_suppressedFingerprint == snapshot.fingerprintMaterial) {
            _suppressedFingerprint = null;
            return;
          }
          _insideHandler = true;
          try {
            await handler(snapshot);
          } finally {
            _insideHandler = false;
          }
        })
        .catchError((Object _) {
          // Clipboard contents and platform error details are intentionally not
          // logged. The next watcher event remains eligible for processing.
        })
        .whenComplete(() => _readInFlight = false);
  }

  @override
  Future<ClipboardSnapshot?> read() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return null;
    final reader = await clipboard.read();

    final fileUris = <String>[];
    for (final item in reader.items) {
      if (!item.canProvide(Formats.fileUri)) continue;
      final uri = await item.readValue(Formats.fileUri);
      if (uri != null && uri.isScheme('file')) fileUris.add(uri.toString());
    }
    if (fileUris.isNotEmpty) {
      return ClipboardSnapshot.files(fileUris: fileUris);
    }

    if (reader.canProvide(Formats.png)) {
      final bytes = await _readBoundedFile(reader, Formats.png);
      if (bytes != null && bytes.isNotEmpty) {
        return ClipboardSnapshot.image(data: bytes, mimeType: 'image/png');
      }
    }

    final text = reader.canProvide(Formats.plainText)
        ? await reader.readValue(Formats.plainText)
        : null;
    if (text == null || text.trim().isEmpty) return null;
    final html = reader.canProvide(Formats.htmlText)
        ? await reader.readValue(Formats.htmlText)
        : null;
    return ClipboardSnapshot.text(text: text, html: html);
  }

  @override
  Future<void> write(ClipItem item, {String? textOverride}) async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      throw UnsupportedError('system clipboard is unavailable');
    }
    final writerItems = <DataWriterItem>[];
    switch (item.kind) {
      case ClipKind.image:
        final data = base64Decode(item.dataBase64!);
        final writer = DataWriterItem();
        writer.add(Formats.png(Uint8List.fromList(data)));
        writerItems.add(writer);
      case ClipKind.files:
        for (final value in item.fileUris) {
          final uri = Uri.tryParse(value);
          if (uri == null || !uri.isScheme('file')) continue;
          final writer = DataWriterItem();
          writer.add(Formats.fileUri(uri));
          writerItems.add(writer);
        }
      default:
        final writer = DataWriterItem();
        final text = textOverride ?? item.text!;
        writer.add(Formats.plainText(text));
        if (textOverride == null && item.html != null) {
          writer.add(Formats.htmlText(item.html!));
        }
        writerItems.add(writer);
    }
    if (writerItems.isEmpty) {
      throw const FormatException('clip has no writable representation');
    }

    _suppressedFingerprint = textOverride == null
        ? item.fingerprintMaterial
        : ClipboardSnapshot.text(text: textOverride).fingerprintMaterial;
    await clipboard.write(writerItems);
  }

  Future<Uint8List?> _readBoundedFile(
    ClipboardReader reader,
    FileFormat format,
  ) async {
    final completer = Completer<Uint8List?>();
    final progress = reader.getFile(
      format,
      (file) async {
        if (file.fileSize case final size? when size > maxBinaryBytes) {
          file.close();
          if (!completer.isCompleted) completer.complete(null);
          return;
        }
        final builder = BytesBuilder(copy: false);
        try {
          await for (final chunk in file.getStream()) {
            if (builder.length + chunk.length > maxBinaryBytes) {
              if (!completer.isCompleted) completer.complete(null);
              return;
            }
            builder.add(chunk);
          }
          if (!completer.isCompleted) completer.complete(builder.takeBytes());
        } on Object {
          if (!completer.isCompleted) completer.complete(null);
        }
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete(null);
      },
      allowVirtualFiles: false,
      synthesizeFilesFromURIs: false,
    );
    if (progress == null) return null;
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => null,
    );
  }
}

class MemoryClipClipboardService implements ClipClipboardService {
  MemoryClipClipboardService({this.current});

  ClipboardSnapshot? current;
  ClipItem? lastWritten;
  String? lastTextOverride;
  ClipboardSnapshotHandler? _onSnapshot;

  @override
  bool get monitoring => _onSnapshot != null;

  @override
  Future<void> start(ClipboardSnapshotHandler onSnapshot) async {
    _onSnapshot = onSnapshot;
  }

  @override
  Future<void> stop() async {
    _onSnapshot = null;
  }

  @override
  Future<ClipboardSnapshot?> read() async => current;

  @override
  Future<void> write(ClipItem item, {String? textOverride}) async {
    lastWritten = item;
    lastTextOverride = textOverride;
  }

  Future<void> emit(ClipboardSnapshot snapshot) async {
    current = snapshot;
    await _onSnapshot?.call(snapshot);
  }
}
