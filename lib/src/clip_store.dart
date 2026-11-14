import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../history/capture_policy.dart';
import '../history/clip_item.dart';
import '../history/clip_repository.dart';
import '../history/clipboard_snapshot.dart';
import '../history/text_dedupe.dart';

class CaptureResult {
  const CaptureResult._({
    required this.accepted,
    this.item,
    this.rejectionReason,
    this.refreshedExisting = false,
  });

  const CaptureResult.accepted(ClipItem item, {bool refreshedExisting = false})
    : this._(accepted: true, item: item, refreshedExisting: refreshedExisting);

  const CaptureResult.rejected(CaptureRejectionReason reason)
    : this._(accepted: false, rejectionReason: reason);

  final bool accepted;
  final ClipItem? item;
  final CaptureRejectionReason? rejectionReason;
  final bool refreshedExisting;
}

class ClipStore extends ChangeNotifier {
  ClipStore({
    ClipRepository? repository,
    CapturePolicy? policy,
    DateTime Function()? clock,
  }) : _repository = repository ?? MemoryClipRepository(),
       _policy = policy ?? const CapturePolicy(),
       _clock = clock ?? DateTime.now;

  final ClipRepository _repository;
  final DateTime Function() _clock;
  final List<ClipItem> _clips = <ClipItem>[];
  final List<String> _queuedIds = <String>[];
  Set<String> _semanticMatchIds = const <String>{};
  Future<void> _operationTail = Future<void>.value();
  CapturePolicy _policy;
  String _query = '';
  bool _pinnedOnly = false;
  ClipKind? _kindFilter;
  String? _collectionFilter;
  bool _initialized = false;
  bool _vaultLocked = false;
  String? _statusMessage;
  int _idCounter = 0;
  int _queryGeneration = 0;

  bool get initialized => _initialized;
  bool get vaultLocked => _vaultLocked;
  bool get captureEnabled => _policy.captureEnabled && !_vaultLocked;
  bool get captureLikelySensitive => _policy.captureLikelySensitive;
  String get query => _query;
  bool get pinnedOnly => _pinnedOnly;
  ClipKind? get kindFilter => _kindFilter;
  String? get collectionFilter => _collectionFilter;
  String? get statusMessage => _statusMessage;
  CapturePolicy get policy => _policy;
  List<ClipItem> get clips => List<ClipItem>.unmodifiable(_clips);
  List<String> get queuedIds => List<String>.unmodifiable(_queuedIds);
  int get queueLength => _queuedIds.length;

  Set<String> get collections => _clips
      .map((clip) => clip.collection)
      .whereType<String>()
      .where((value) => value.isNotEmpty)
      .toSet();

  List<ClipItem> get visibleClips {
    final normalized = _query.trim().toLowerCase();
    final result = _clips
        .where((clip) => !(_pinnedOnly && !clip.pinned))
        .where((clip) => _kindFilter == null || clip.kind == _kindFilter)
        .where(
          (clip) =>
              _collectionFilter == null || clip.collection == _collectionFilter,
        )
        .where(
          (clip) =>
              normalized.isEmpty ||
              clip.searchableText.contains(normalized) ||
              _semanticMatchIds.contains(clip.id),
        )
        .toList(growable: false);
    result.sort((a, b) {
      final pinOrder = (b.pinned ? 1 : 0).compareTo(a.pinned ? 1 : 0);
      if (pinOrder != 0) return pinOrder;
      return b.sortTimestamp.compareTo(a.sortTimestamp);
    });
    return result;
  }

  Future<void> initialize() => _enqueue(() async {
    if (_initialized) return;
    try {
      final loaded = await _repository.load();
      _clips
        ..clear()
        ..addAll(loaded);
      final beforePrune = _clips.length;
      _prune(_clock().toUtc());
      if (_clips.length != beforePrune) {
        await _repository.save(List<ClipItem>.of(_clips));
      }
      _initialized = true;
      _vaultLocked = false;
      _statusMessage = null;
    } on Object {
      _clips.clear();
      _queuedIds.clear();
      _initialized = true;
      _vaultLocked = true;
      _policy = _policy.copyWith(captureEnabled: false);
      _statusMessage = 'Encrypted history is locked. Capture remains off.';
    }
    notifyListeners();
  });

  void setQuery(String value) {
    if (_query == value) return;
    _query = value;
    _queryGeneration += 1;
    final generation = _queryGeneration;
    _semanticMatchIds = const <String>{};
    notifyListeners();
    final normalized = value.trim();
    final repository = _repository;
    if (normalized.length >= 2) {
      if (repository is! SemanticClipRepository) return;
      unawaited(
        _loadSemanticMatches(
          repository as SemanticClipRepository,
          normalized,
          generation,
        ),
      );
    }
  }

  Future<void> _loadSemanticMatches(
    SemanticClipRepository repository,
    String query,
    int generation,
  ) async {
    try {
      final matches = await repository.semanticSearchIds(query);
      if (generation != _queryGeneration) return;
      _semanticMatchIds = matches.toSet();
      notifyListeners();
    } on Object {
      // Lexical search remains available if the local vector index is damaged.
    }
  }

  void setPinnedOnly(bool value) {
    if (_pinnedOnly == value) return;
    _pinnedOnly = value;
    notifyListeners();
  }

  void setKindFilter(ClipKind? value) {
    if (_kindFilter == value) return;
    _kindFilter = value;
    notifyListeners();
  }

  void setCollectionFilter(String? value) {
    if (_collectionFilter == value) return;
    _collectionFilter = value;
    notifyListeners();
  }

  void setCaptureEnabled(bool value) {
    if (_vaultLocked || _policy.captureEnabled == value) return;
    _policy = _policy.copyWith(captureEnabled: value);
    _statusMessage = value
        ? 'Clipboard capture resumed'
        : 'Clipboard capture paused';
    notifyListeners();
  }

  void setCaptureLikelySensitive(bool value) {
    if (_policy.captureLikelySensitive == value) return;
    _policy = _policy.copyWith(captureLikelySensitive: value);
    notifyListeners();
  }

  void setIgnoredApplications(Set<String> applications) {
    _policy = _policy.copyWith(
      ignoredApplications: Set<String>.of(applications),
    );
    notifyListeners();
  }

  Future<void> setHistoryLimit(int value) => _enqueue(() async {
    if (value < 1 || value > 100000) {
      throw const ClipInputException(
        'History limit must be between 1 and 100,000 items',
      );
    }
    if (_policy.maxHistoryItems == value) return;
    final previous = _policy;
    _policy = _policy.copyWith(maxHistoryItems: value);
    try {
      await _commit(() {
        _statusMessage = 'History limit updated to $value items';
      });
    } on Object {
      _policy = previous.copyWith(captureEnabled: false);
      rethrow;
    }
  });

  void setStatusMessage(String? message) {
    if (_statusMessage == message) return;
    _statusMessage = message;
    notifyListeners();
  }

  Future<CaptureResult> capture(
    ClipboardSnapshot snapshot,
  ) => _enqueue(() async {
    if (_vaultLocked) {
      return const CaptureResult.rejected(
        CaptureRejectionReason.vaultUnavailable,
      );
    }
    final rejection = _policy.evaluate(snapshot);
    if (rejection != null) {
      _statusMessage = captureRejectionLabel(rejection);
      notifyListeners();
      return CaptureResult.rejected(rejection);
    }

    final now = _clock().toUtc();
    final encodedData = snapshot.data == null
        ? null
        : base64Encode(snapshot.data!);
    // Text: every clip whose text is verbatim equal is a duplicate (see
    // text_dedupe.dart). Images/files: only an identical fingerprint.
    final textKey = snapshotTextKey(snapshot);
    final duplicates =
        _clips
            .where(
              (clip) => textKey != null
                  ? clipTextKey(clip) == textKey
                  : clip.fingerprintMaterial == snapshot.fingerprintMaterial,
            )
            .toList()
          ..sort(compareYoungestFirst);
    final existing = duplicates.isEmpty ? null : duplicates.first;
    final captured = ClipItem(
      id: existing?.id ?? _nextId(now),
      kind: snapshot.kind,
      title:
          existing?.title ??
          defaultClipTitle(
            snapshot.kind,
            text: snapshot.text,
            fileUris: snapshot.fileUris,
          ),
      text: snapshot.text,
      html: snapshot.html,
      dataBase64: encodedData,
      mimeType: snapshot.mimeType,
      fileUris: List<String>.of(snapshot.fileUris),
      sourceApplication: snapshot.sourceApplication,
      createdAt: now,
      lastUsedAt: now,
      pinned: existing?.pinned ?? false,
      collection: existing?.collection,
      tags: existing?.tags ?? const <String>{},
    );
    // The new copy is the youngest; it keeps what the user set on any of
    // the older copies, which are removed.
    final item = duplicates.length > 1
        ? mergeDuplicateMetadata(captured, duplicates.skip(1))
        : captured;
    item.validate();
    final removedIds = duplicates.map((clip) => clip.id).toSet();

    await _commit(() {
      _clips.removeWhere((clip) => removedIds.contains(clip.id));
      _queuedIds.removeWhere((id) => removedIds.contains(id) && id != item.id);
      _clips.add(item);
      _statusMessage = duplicates.isNotEmpty
          ? 'Existing item moved to the top'
          : '${item.kind.label} captured';
    });
    return CaptureResult.accepted(
      item,
      refreshedExisting: duplicates.isNotEmpty,
    );
  });

  Future<CaptureResult> addText(String text) =>
      capture(ClipboardSnapshot.text(text: text));

  Future<void> togglePinned(String id) => _enqueue(() async {
    await _commit(() {
      final index = _indexOf(id);
      _clips[index] = _clips[index].copyWith(pinned: !_clips[index].pinned);
    });
  });

  Future<void> rename(String id, String title) => _enqueue(() async {
    final trimmed = title.trim();
    if (trimmed.isEmpty || trimmed.length > 512) {
      throw const ClipInputException('Titles must be 1 to 512 characters');
    }
    await _commit(() {
      final index = _indexOf(id);
      _clips[index] = _clips[index].copyWith(title: trimmed);
    });
  });

  Future<void> setCollection(String id, String? collection) =>
      _enqueue(() async {
        final normalized = collection?.trim();
        if (normalized != null && normalized.length > 160) {
          throw const ClipInputException(
            'Collection names must be at most 160 characters',
          );
        }
        await _commit(() {
          final index = _indexOf(id);
          _clips[index] = _clips[index].copyWith(
            collection: normalized,
            clearCollection: normalized == null || normalized.isEmpty,
          );
        });
      });

  Future<void> setTags(String id, Set<String> tags) => _enqueue(() async {
    final normalized = tags
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toSet();
    if (normalized.length > 32 || normalized.any((tag) => tag.length > 80)) {
      throw const ClipInputException(
        'Use at most 32 tags of up to 80 characters each',
      );
    }
    await _commit(() {
      final index = _indexOf(id);
      _clips[index] = _clips[index].copyWith(tags: normalized);
    });
  });

  /// Replaces the text of a text-like clip. The edited text goes through the
  /// same size and likely-secret policy as captured text (but not the pause
  /// switch: editing is an explicit user action). An auto-generated title is
  /// regenerated; a title the user chose is kept.
  Future<void> editText(String id, String text) => _enqueue(() async {
    final index = _indexOf(id);
    final existing = _clips[index];
    if (existing.text == null || existing.kind == ClipKind.files) {
      throw const ClipInputException('Only text clips can be edited');
    }
    if (text == existing.text) return;
    final duplicate = _clips.indexWhere(
      (clip) => clip.id != id && clipTextKey(clip) == text,
    );
    if (duplicate >= 0) {
      // Two clips with identical content would break capture de-duplication.
      throw const ClipInputException(
        'An identical clip is already in your history',
      );
    }
    final snapshot = ClipboardSnapshot.text(
      text: text,
      sourceApplication: existing.sourceApplication,
    );
    final rejection = _policy.copyWith(captureEnabled: true).evaluate(snapshot);
    if (rejection != null) {
      _statusMessage = captureRejectionLabel(rejection);
      notifyListeners();
      throw ClipInputException(captureRejectionLabel(rejection));
    }
    final autoTitle =
        existing.title ==
        defaultClipTitle(
          existing.kind,
          text: existing.text,
          fileUris: existing.fileUris,
        );
    final edited = ClipItem(
      id: existing.id,
      kind: snapshot.kind,
      title: autoTitle
          ? defaultClipTitle(snapshot.kind, text: text)
          : existing.title,
      text: text,
      sourceApplication: existing.sourceApplication,
      createdAt: existing.createdAt,
      lastUsedAt: _clock().toUtc(),
      pinned: existing.pinned,
      collection: existing.collection,
      tags: existing.tags,
    );
    edited.validate();
    await _commit(() {
      _clips[index] = edited;
      _statusMessage = 'Clip updated';
    });
  });

  Future<void> delete(String id) => _enqueue(() async {
    await _commit(() {
      final index = _indexOf(id);
      _clips.removeAt(index);
      _queuedIds.remove(id);
    });
  });

  Future<void> clearUnpinned() => _enqueue(() async {
    await _commit(() {
      final removedIds = _clips
          .where((clip) => !clip.pinned)
          .map((clip) => clip.id)
          .toSet();
      _clips.removeWhere((clip) => !clip.pinned);
      _queuedIds.removeWhere(removedIds.contains);
      _statusMessage = 'Unpinned history cleared';
    });
  });

  Future<void> markUsed(String id) => _enqueue(() async {
    await _commit(() {
      final index = _indexOf(id);
      _clips[index] = _clips[index].copyWith(lastUsedAt: _clock().toUtc());
    });
  });

  void toggleQueued(String id) {
    _indexOf(id);
    if (_queuedIds.contains(id)) {
      _queuedIds.remove(id);
    } else {
      _queuedIds.add(id);
    }
    notifyListeners();
  }

  ClipItem? takeNextQueued() {
    while (_queuedIds.isNotEmpty) {
      final id = _queuedIds.removeAt(0);
      final index = _clips.indexWhere((clip) => clip.id == id);
      if (index >= 0) {
        notifyListeners();
        return _clips[index];
      }
    }
    notifyListeners();
    return null;
  }

  ClipItem itemById(String id) => _clips[_indexOf(id)];

  /// Lookup without copying the history (unlike [clips]).
  ClipItem? findById(String id) {
    for (final clip in _clips) {
      if (clip.id == id) return clip;
    }
    return null;
  }

  /// The [limit] most recently used clips, newest first, without sorting or
  /// copying the whole history.
  List<ClipItem> mostRecent(int limit) {
    final top = <ClipItem>[];
    for (final clip in _clips) {
      var index = top.length;
      while (index > 0 &&
          top[index - 1].sortTimestamp.isBefore(clip.sortTimestamp)) {
        index -= 1;
      }
      if (index < limit) {
        top.insert(index, clip);
        if (top.length > limit) top.removeLast();
      }
    }
    return top;
  }

  /// Background de-duplication sweep: removes older verbatim-text duplicates
  /// (keeping the youngest, with merged pin/tags/collection). Duplicates can
  /// predate this rule, arrive by restore/import, or be created by edits on
  /// another device. Returns how many clips were removed.
  Future<int> dedupeText() => _enqueue(() async {
    if (_vaultLocked || !_initialized) return 0;
    final plan = planTextDedupe(_clips);
    if (plan.isEmpty) return 0;
    await _commit(() {
      _clips.removeWhere((clip) => plan.removedIds.contains(clip.id));
      for (final (index, clip) in _clips.indexed) {
        final keeper = plan.keepers[clip.id];
        if (keeper != null) _clips[index] = keeper;
      }
      _queuedIds.removeWhere(plan.removedIds.contains);
    });
    return plan.removedIds.length;
  });

  /// Undo for [delete]: puts a removed clip back unless an identical clip
  /// was captured in the meantime.
  Future<void> restore(ClipItem clip) => _enqueue(() async {
    final textKey = clipTextKey(clip);
    if (_clips.any(
      (existing) =>
          existing.id == clip.id ||
          (textKey != null && clipTextKey(existing) == textKey) ||
          existing.fingerprintMaterial == clip.fingerprintMaterial,
    )) {
      return;
    }
    clip.validate();
    await _commit(() {
      _clips.add(clip);
      _statusMessage = 'Clip restored';
    });
  });

  Future<void> eraseVault() => _enqueue(() async {
    await _repository.clear();
    _clips.clear();
    _queuedIds.clear();
    _vaultLocked = false;
    _policy = _policy.copyWith(captureEnabled: false);
    _statusMessage = 'Encrypted history erased. Capture remains paused.';
    notifyListeners();
  });

  Future<void> _commit(VoidCallback mutation) async {
    if (_vaultLocked) {
      throw const ClipRepositoryException('encrypted vault is locked');
    }
    final before = List<ClipItem>.of(_clips);
    final beforeQueue = List<String>.of(_queuedIds);
    final beforeStatus = _statusMessage;
    mutation();
    _prune(_clock().toUtc());
    notifyListeners();
    try {
      await _repository.save(List<ClipItem>.of(_clips));
    } on Object {
      _clips
        ..clear()
        ..addAll(before);
      _queuedIds
        ..clear()
        ..addAll(beforeQueue);
      _statusMessage = beforeStatus;
      _vaultLocked = true;
      _policy = _policy.copyWith(captureEnabled: false);
      _statusMessage = 'Encrypted history write failed. Capture is locked.';
      notifyListeners();
      throw const ClipRepositoryException('encrypted history write failed');
    }
  }

  void _prune(DateTime now) {
    final cutoff = now.subtract(_policy.retention);
    final removed = _clips
        .where((clip) => !clip.pinned && clip.createdAt.isBefore(cutoff))
        .map((clip) => clip.id)
        .toSet();
    _clips.removeWhere((clip) => removed.contains(clip.id));

    final unpinned = _clips.where((clip) => !clip.pinned).toList()
      ..sort((a, b) => b.sortTimestamp.compareTo(a.sortTimestamp));
    if (unpinned.length > _policy.maxHistoryItems) {
      removed.addAll(
        unpinned.skip(_policy.maxHistoryItems).map((clip) => clip.id),
      );
      _clips.removeWhere((clip) => removed.contains(clip.id));
    }
    _queuedIds.removeWhere(removed.contains);
  }

  int _indexOf(String id) {
    final index = _clips.indexWhere((clip) => clip.id == id);
    if (index < 0) throw StateError('clip not found');
    return index;
  }

  String _nextId(DateTime now) {
    _idCounter += 1;
    return '${now.microsecondsSinceEpoch.toRadixString(36)}-${_idCounter.toRadixString(36)}';
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        completer.complete(await operation());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}

/// A rejected user edit whose [message] is safe to show: it is a fixed string
/// and never contains clipboard content (unlike e.g. a JSON decode error).
class ClipInputException extends FormatException {
  const ClipInputException(super.message);
}
