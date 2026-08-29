import 'dart:convert';

import 'package:cliptown_app/history/clip_item.dart';
import 'package:cliptown_app/history/clip_repository.dart';
import 'package:cliptown_app/src/clip_store.dart';

List<ClipItem> demoClipItems() {
  final base = DateTime.utc(2026, 8, 22, 12);
  return <ClipItem>[
    ClipItem(
      id: 'deploy-command',
      kind: ClipKind.code,
      title: 'Deploy command',
      text: 'kubectl rollout status deployment/cliptown-api',
      createdAt: base,
      lastUsedAt: base,
      pinned: true,
      collection: 'Operations',
      tags: const <String>{'kubernetes'},
    ),
    ClipItem(
      id: 'design-reference',
      kind: ClipKind.image,
      title: 'Skyline logo',
      dataBase64: base64Encode(_onePixelPng),
      mimeType: 'image/png',
      createdAt: base.subtract(const Duration(minutes: 1)),
      lastUsedAt: base.subtract(const Duration(minutes: 1)),
    ),
    ClipItem(
      id: 'security-notes',
      kind: ClipKind.text,
      title: 'Security notes',
      text: 'Random account master key; PIN unlocks wrapped key material.',
      createdAt: base.subtract(const Duration(minutes: 2)),
      lastUsedAt: base.subtract(const Duration(minutes: 2)),
    ),
  ];
}

Future<ClipStore> createDemoStore() async {
  final store = ClipStore(
    repository: MemoryClipRepository(seed: demoClipItems()),
  );
  await store.initialize();
  return store;
}

const List<int> _onePixelPng = <int>[
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  1,
  8,
  6,
  0,
  0,
  0,
  31,
  21,
  196,
  137,
  0,
  0,
  0,
  13,
  73,
  68,
  65,
  84,
  8,
  215,
  99,
  248,
  207,
  192,
  240,
  31,
  0,
  5,
  0,
  1,
  255,
  137,
  153,
  61,
  29,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
];
