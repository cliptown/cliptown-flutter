import 'package:flutter/foundation.dart';

@immutable
class ClipPreview {
  const ClipPreview({
    required this.id,
    required this.title,
    required this.detail,
    required this.kind,
    required this.updatedAt,
    this.pinned = false,
  });

  final String id;
  final String title;
  final String detail;
  final String kind;
  final DateTime updatedAt;
  final bool pinned;

  ClipPreview copyWith({bool? pinned}) => ClipPreview(
    id: id,
    title: title,
    detail: detail,
    kind: kind,
    updatedAt: updatedAt,
    pinned: pinned ?? this.pinned,
  );
}

class ClipStore extends ChangeNotifier {
  ClipStore({List<ClipPreview>? seed})
    : _clips = List<ClipPreview>.of(seed ?? demoClips);

  final List<ClipPreview> _clips;
  String _query = '';
  bool _pinnedOnly = false;

  String get query => _query;
  bool get pinnedOnly => _pinnedOnly;

  List<ClipPreview> get visibleClips {
    final normalized = _query.trim().toLowerCase();
    return _clips
        .where((clip) => !(_pinnedOnly && !clip.pinned))
        .where(
          (clip) =>
              normalized.isEmpty ||
              '${clip.title} ${clip.detail} ${clip.kind}'
                  .toLowerCase()
                  .contains(normalized),
        )
        .toList(growable: false)
      ..sort((a, b) {
        final pinOrder = (b.pinned ? 1 : 0).compareTo(a.pinned ? 1 : 0);
        return pinOrder != 0 ? pinOrder : b.updatedAt.compareTo(a.updatedAt);
      });
  }

  void setQuery(String value) {
    if (_query == value) return;
    _query = value;
    notifyListeners();
  }

  void setPinnedOnly(bool value) {
    if (_pinnedOnly == value) return;
    _pinnedOnly = value;
    notifyListeners();
  }

  void togglePinned(String id) {
    final index = _clips.indexWhere((clip) => clip.id == id);
    if (index < 0) return;
    _clips[index] = _clips[index].copyWith(pinned: !_clips[index].pinned);
    notifyListeners();
  }

  static final List<ClipPreview> demoClips = <ClipPreview>[
    ClipPreview(
      id: 'deploy-command',
      title: 'Deploy command',
      detail: 'kubectl rollout status deployment/cliptown-api',
      kind: 'Text',
      pinned: true,
      updatedAt: DateTime.utc(2026, 7, 27, 12),
    ),
    ClipPreview(
      id: 'design-reference',
      title: 'Skyline logo',
      detail: 'Encrypted image preview • 384 KB',
      kind: 'Image',
      updatedAt: DateTime.utc(2026, 7, 27, 11),
    ),
    ClipPreview(
      id: 'security-notes',
      title: 'Security notes',
      detail: 'Random account master key; PIN unlocks wrapped key material.',
      kind: 'Text',
      updatedAt: DateTime.utc(2026, 7, 27, 10),
    ),
  ];
}
