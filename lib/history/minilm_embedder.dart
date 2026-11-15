import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';

import 'local_embedding.dart';

/// The runtime boundary is injectable so index tests need no model or network.
abstract interface class LocalTextEmbeddingModel {
  String get modelId;
  Future<List<double>> embed(String text);
}

/// Native MiniLM encoder. Only model weights are downloaded; clipboard content
/// never leaves the device. The verified model is cached in app support storage.
final class MiniLmOnDeviceEmbedder implements LocalTextEmbeddingModel {
  MiniLmOnDeviceEmbedder({required this.modelDirectory});

  final Directory modelDirectory;
  Future<LlamaEngine>? _loading;

  @override
  String get modelId => 'cliptown-minilm-l6-v2-q4-gguf-v1';

  @override
  Future<List<double>> embed(String text) async {
    if (text.trim().isEmpty) {
      throw const FormatException('cannot embed empty text');
    }
    // MiniLM is trained on short spans. Avoid feeding huge clipboard payloads
    // through the native tokenizer; lexical search still sees the full text.
    final bounded = text.length > 4096 ? text.substring(0, 4096) : text;
    final engine = await (_loading ??= _loadEngine());
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

  Future<LlamaEngine> _loadEngine() async {
    final model = await ensureMiniLmModelFile(modelDirectory);
    final engine = LlamaEngine(LlamaBackend());
    try {
      await engine.loadModel(
        model.path,
        modelParams: ModelParams(contextSize: 512, gpuLayers: 0),
      );
      if (!engine.supportsEmbeddings) {
        throw StateError('MiniLM runtime does not support embeddings');
      }
      return engine;
    } on Object {
      await engine.dispose();
      rethrow;
    }
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
Future<File> ensureMiniLmModelFile(Directory directory) async {
  await directory.create(recursive: true);
  final model = File(
    '${directory.path}${Platform.pathSeparator}$miniLmFilename',
  );
  if (await model.exists() && await _matchesModelDigest(model)) return model;

  final partial = File('${model.path}.partial');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client.getUrl(Uri.parse(miniLmDownloadUrl));
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok ||
        response.contentLength > _maxModelBytes) {
      throw const FileSystemException('MiniLM model download failed');
    }
    final sink = partial.openWrite();
    var written = 0;
    try {
      await for (final bytes in response) {
        written += bytes.length;
        if (written > _maxModelBytes) {
          throw const FileSystemException('MiniLM model exceeds size limit');
        }
        sink.add(bytes);
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
