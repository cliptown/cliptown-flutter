import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';

import '../local_embedding.dart';

/// The runtime boundary is injectable so index tests need no model or network.
abstract interface class LocalTextEmbeddingModel {
  String get modelId;
  Future<List<double>> embed(String text);
}

/// Optional cleanup contract for models with native resources.
abstract interface class DisposableLocalTextEmbeddingModel {
  Future<void> dispose();
}

/// Native MiniLM encoder. Only model weights are downloaded; clipboard content
/// never leaves the device. The verified model is cached in app support storage.
final class MiniLmOnDeviceEmbedder
    implements LocalTextEmbeddingModel, DisposableLocalTextEmbeddingModel {
  MiniLmOnDeviceEmbedder({
    required this.modelDirectory,
    this.onDownloadProgress,
  });

  final Directory modelDirectory;
  final void Function(int downloadedBytes, int? totalBytes)? onDownloadProgress;
  Future<LlamaEngine>? _loading;
  Future<void> _tail = Future<void>.value();
  bool _disposed = false;

  @override
  String get modelId => 'cliptown-minilm-l6-v2-q4-gguf-v1';

  @override
  Future<List<double>> embed(String text) {
    if (_disposed) {
      return Future<List<double>>.error(StateError('closed model'));
    }
    // llama.cpp contexts are not concurrently reentrant. Search and backfill
    // both share this one serialization queue.
    final operation = _tail.then((_) => _embedOnce(text));
    _tail = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<List<double>> _embedOnce(String text) async {
    if (text.trim().isEmpty) {
      throw const FormatException('cannot embed empty text');
    }
    // MiniLM is trained on short spans. Avoid feeding huge clipboard payloads
    // through the native tokenizer; lexical search still sees the full text.
    var bounded = text.length > 4096 ? text.substring(0, 4096) : text;
    final engine = await _ensureEngine();
    // BERT-family GGUF encoders evaluate an entire input in one micro-batch.
    // Count real model tokens rather than assuming a character limit is safe.
    while (bounded.length > 1 && await engine.getTokenCount(bounded) > 240) {
      bounded = bounded.substring(0, (bounded.length / 2).ceil());
    }
    final vector = await engine.embed(bounded, normalize: true);
    if (vector.length != localEmbeddingDimensions ||
        vector.any((value) => !value.isFinite)) {
      throw const FormatException('MiniLM returned an invalid embedding');
    }
    final norm = math.sqrt(
      vector.fold<double>(0, (sum, value) => sum + value * value),
    );
    if (!norm.isFinite || norm < 0.000001) {
      throw const FormatException('MiniLM returned a zero-length embedding');
    }
    return vector;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _tail;
    if (_loading case final pending?) {
      try {
        final engine = await pending;
        await engine.dispose();
      } on Object {
        // A failed model load has no native resources to release.
      }
    }
    _loading = null;
  }

  // A first-launch offline failure must not poison this session forever.
  // A subsequent save/search can retry once the model is available.
  Future<LlamaEngine> _ensureEngine() async {
    final loading = _loading ??= _loadEngine();
    try {
      return await loading;
    } on Object {
      if (identical(_loading, loading)) _loading = null;
      rethrow;
    }
  }

  Future<LlamaEngine> _loadEngine() async {
    final model = await ensureMiniLmModelFile(
      modelDirectory,
      onDownloadProgress: onDownloadProgress,
    );
    final engine = await LlamaEngine.load(
      LlamaModel(ModelSource.path(model.path)),
      params: const ModelParams(contextSize: 512, gpuLayers: 0),
    );
    if (!engine.supportsEmbeddings) {
      await engine.dispose();
      throw StateError('MiniLM runtime does not support embeddings');
    }
    return engine;
  }
}

const String miniLmFilename = 'all-MiniLM-L6-v2-Q4_K_M.gguf';
const String miniLmDownloadUrl =
    'https://huggingface.co/smarttasks/all-MiniLM-L6-v2-GGUF/'
    'resolve/main/all-MiniLM-L6-v2-Q4_K_M.gguf';
const String miniLmSha256 =
    '3567b0d6509ce7680989831fa57ee799484336565df8c21af3fe236f0ce338a6';
const int _maxModelBytes = 32 * 1024 * 1024;

/// Verifies cached weights on every startup and checks the download before
/// atomic installation. Failed/interrupted downloads never become a model.
Future<File> ensureMiniLmModelFile(
  Directory directory, {
  void Function(int downloadedBytes, int? totalBytes)? onDownloadProgress,
}) async {
  await directory.create(recursive: true);
  final model = File(
    '${directory.path}${Platform.pathSeparator}$miniLmFilename',
  );
  if (await model.exists() && await _matchesModelDigest(model)) return model;

  final partial = File('${model.path}.partial');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client
        .getUrl(Uri.parse(miniLmDownloadUrl))
        .timeout(const Duration(seconds: 20));
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode != HttpStatus.ok ||
        response.contentLength > _maxModelBytes) {
      throw const FileSystemException('MiniLM model download failed');
    }
    final expected = response.contentLength > 0 ? response.contentLength : null;
    onDownloadProgress?.call(0, expected);
    final sink = partial.openWrite();
    var written = 0;
    try {
      final started = Stopwatch()..start();
      await for (final bytes in response.timeout(const Duration(seconds: 30))) {
        if (started.elapsed > const Duration(minutes: 2)) {
          throw const FileSystemException('MiniLM download timed out');
        }
        written += bytes.length;
        if (written > _maxModelBytes) {
          throw const FileSystemException('MiniLM model exceeds size limit');
        }
        sink.add(bytes);
        onDownloadProgress?.call(written, expected);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (written < 1024 * 1024 || !await _matchesModelDigest(partial)) {
      throw const FormatException('MiniLM model SHA-256 mismatch');
    }
    if (await model.exists()) await model.delete();
    await partial.rename(model.path);
    return model;
  } finally {
    client.close(force: true);
    if (await partial.exists()) await partial.delete();
  }
}

Future<bool> _matchesModelDigest(File file) async {
  if (await file.length() > _maxModelBytes) return false;
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString() == miniLmSha256;
}
