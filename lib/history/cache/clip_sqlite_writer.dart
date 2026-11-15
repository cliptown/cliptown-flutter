import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../clip_item.dart';
import '../local_embedding.dart';
import 'clip_persistence_state.dart';
import 'clip_write_plan.dart';

/// Apply only changed rows inside the caller's BEGIN IMMEDIATE transaction.
/// Foreign keys cascade deletions from clips into legacy embeddings.
ClipWriteStats applyClipWritePlan(
  Database database,
  ClipWritePlan plan, {
  required bool generateLegacyEmbeddings,
}) {
  final deleteClip = database.prepare('DELETE FROM clips WHERE clip_id = ?');
  final insertClip = database.prepare('''
    INSERT INTO clips (
      clip_id, kind, title, search_text, clip_json, sort_timestamp, pinned
    ) VALUES (?, ?, ?, ?, ?, ?, ?)
  ''');
  final updateClip = database.prepare('''
    UPDATE clips SET
      kind = ?, title = ?, search_text = ?, clip_json = ?,
      sort_timestamp = ?, pinned = ?
    WHERE clip_id = ?
  ''');
  final deleteEmbedding = database.prepare(
    'DELETE FROM clip_embeddings WHERE clip_id = ?',
  );
  final insertEmbedding = database.prepare('''
    INSERT INTO clip_embeddings (
      clip_id, model_id, dimensions, embedding, created_at
    ) VALUES (?, ?, ?, ?, ?)
  ''');

  var embeddingsRebuilt = 0;
  try {
    for (final id in plan.deletedIds) {
      deleteClip.execute(<Object?>[id]);
    }
    for (final clip in plan.inserted) {
      insertClip.execute(<Object?>[
        clip.id,
        clip.kind.name,
        clip.title,
        clip.searchableText,
        jsonEncode(clip.toJson()),
        clip.sortTimestamp.toUtc().toIso8601String(),
        clip.pinned ? 1 : 0,
      ]);
    }
    for (final clip in plan.updated) {
      updateClip.execute(<Object?>[
        clip.kind.name,
        clip.title,
        clip.searchableText,
        jsonEncode(clip.toJson()),
        clip.sortTimestamp.toUtc().toIso8601String(),
        clip.pinned ? 1 : 0,
        clip.id,
      ]);
    }
    // Only content edits and new clips require new embeddings. Pinning,
    // renaming, tags, collection and mark-used preserve the original vector.
    for (final clip in <ClipItem>[...plan.inserted, ...plan.updated]) {
      if (plan.before[clip.id] case final previous?
          when previous.text == clip.text) {
        continue;
      }
      deleteEmbedding.execute(<Object?>[clip.id]);
      if (!generateLegacyEmbeddings ||
          clip.text == null ||
          clip.text!.trim().isEmpty) {
        continue;
      }
      insertEmbedding.execute(<Object?>[
        clip.id,
        localEmbeddingModel,
        localEmbeddingDimensions,
        encodeLocalEmbedding(createLocalEmbedding(clip.text!)),
        DateTime.now().toUtc().toIso8601String(),
      ]);
      embeddingsRebuilt += 1;
    }
    // Desktop's neural index is separate; never carry obsolete token-hash
    // vectors forward if a pre-MiniLM vault is opened with this mode disabled.
    if (!generateLegacyEmbeddings) {
      database.execute('DELETE FROM clip_embeddings');
    }
  } finally {
    deleteClip.close();
    insertClip.close();
    updateClip.close();
    deleteEmbedding.close();
    insertEmbedding.close();
  }
  return ClipWriteStats(
    inserted: plan.inserted.length,
    updated: plan.updated.length,
    deleted: plan.deletedIds.length,
    embeddingsRebuilt: embeddingsRebuilt,
  );
}
