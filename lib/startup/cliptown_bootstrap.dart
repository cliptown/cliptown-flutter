import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../clipboard/clipboard_controller.dart';
import '../clipboard/clipboard_service.dart';
import '../cliptown_app.dart';
import '../desktop/desktop_lifecycle_host.dart';
import '../history/clip_item.dart';
import '../history/clip_repository.dart';
import '../history/sqlite_clip_repository.dart';
import '../src/clip_store.dart';
import '../state/app_state_machine.dart';

typedef ClipTownStartup = Future<ClipTownStartupResources> Function();

final class ClipTownStartupResources {
  const ClipTownStartupResources({
    required this.store,
    required this.stateMachine,
    required this.runtimeKind,
    required this.clipboardController,
    required this.desktopLifecycleHost,
    required this.desktopBackgroundEnabled,
    required this.desktopHotKeyEnabled,
  });

  final ClipStore store;
  final AppStateMachine stateMachine;
  final AppRuntimeKind runtimeKind;
  final ClipboardController clipboardController;
  final DesktopLifecycleHost? desktopLifecycleHost;
  final bool desktopBackgroundEnabled;
  final bool desktopHotKeyEnabled;

  void disposeFlutterOwned() {
    clipboardController.dispose();
    store.dispose();
  }

  Future<void> disposeAll() async {
    clipboardController.dispose();
    stateMachine.dispose();
    store.dispose();
    await desktopLifecycleHost?.dispose();
  }
}

Future<ClipTownStartupResources> bootstrapClipTownRuntime() async {
  ClipRepository repository;
  try {
    repository = await createPlatformSqliteClipRepository();
  } on Object {
    repository = const _UnavailableClipRepository();
  }

  final store = ClipStore(repository: repository);
  AppStateMachine? stateMachine;
  ClipboardController? clipboardController;
  DesktopLifecycleHost? desktopLifecycleHost;
  try {
    await store.initialize();

    final isDesktop =
        Platform.isMacOS || Platform.isWindows || Platform.isLinux;
    final runtime = isDesktop
        ? AppRuntimeKind.desktop
        : AppRuntimeKind.mobile;
    stateMachine = store.vaultLocked
        ? AppStateMachine.vaultUnavailable(runtime)
        : AppStateMachine.localReady(
            runtime,
            captureRequested: store.captureEnabled,
          );

    var desktopBackgroundEnabled = false;
    var desktopHotKeyEnabled = false;
    if (isDesktop) {
      final candidate = DesktopLifecycleHost(stateMachine: stateMachine);
      try {
        desktopBackgroundEnabled = await candidate.initialize();
        desktopHotKeyEnabled = candidate.hotKeyReady;
        desktopLifecycleHost = candidate;
      } on Object {
        await candidate.dispose();
      }
    }

    clipboardController = ClipboardController(
      store: store,
      service: SystemClipClipboardService(),
      automaticCaptureSupported: isDesktop,
      stateMachine: stateMachine,
    );
    await clipboardController.initialize();

    return ClipTownStartupResources(
      store: store,
      stateMachine: stateMachine,
      runtimeKind: runtime,
      clipboardController: clipboardController,
      desktopLifecycleHost: desktopLifecycleHost,
      desktopBackgroundEnabled: desktopBackgroundEnabled,
      desktopHotKeyEnabled: desktopHotKeyEnabled,
    );
  } catch (_) {
    clipboardController?.dispose();
    stateMachine?.dispose();
    store.dispose();
    await desktopLifecycleHost?.dispose();
    rethrow;
  }
}

class ClipTownBootstrapApp extends StatefulWidget {
  const ClipTownBootstrapApp({
    super.key,
    this.startup,
    this.startupTimeout = const Duration(seconds: 15),
  });

  final ClipTownStartup? startup;
  final Duration startupTimeout;

  @override
  State<ClipTownBootstrapApp> createState() => _ClipTownBootstrapAppState();
}

enum _StartupPhase { starting, ready, failed }

class _ClipTownBootstrapAppState extends State<ClipTownBootstrapApp> {
  _StartupPhase _phase = _StartupPhase.starting;
  ClipTownStartupResources? _resources;
  String? _failureMessage;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start());
    });
  }

  Future<void> _start() async {
    final attempt = ++_attempt;
    if (mounted) {
      setState(() {
        _phase = _StartupPhase.starting;
        _failureMessage = null;
      });
    }

    final source = (widget.startup ?? bootstrapClipTownRuntime)();
    try {
      final resources = await source.timeout(widget.startupTimeout);
      _accept(resources, attempt);
    } on TimeoutException {
      _fail(
        attempt,
        'The encrypted clipboard vault took too long to open. It remains locked; retry when the device is ready.',
      );
      unawaited(_acceptLateCompletion(source, attempt));
    } catch (_) {
      _fail(
        attempt,
        'ClipTown could not prepare its encrypted local vault. Clipboard capture remains disabled.',
      );
    }
  }

  Future<void> _acceptLateCompletion(
    Future<ClipTownStartupResources> source,
    int attempt,
  ) async {
    try {
      final resources = await source;
      _accept(resources, attempt);
    } catch (_) {
      // The bounded failure state remains visible and retryable.
    }
  }

  void _accept(ClipTownStartupResources resources, int attempt) {
    if (!mounted || attempt != _attempt) {
      unawaited(resources.disposeAll());
      return;
    }
    _resources?.disposeFlutterOwned();
    setState(() {
      _resources = resources;
      _phase = _StartupPhase.ready;
      _failureMessage = null;
    });
  }

  void _fail(int attempt, String message) {
    if (!mounted || attempt != _attempt) return;
    setState(() {
      _phase = _StartupPhase.failed;
      _failureMessage = message;
    });
  }

  @override
  void dispose() {
    _attempt += 1;
    _resources?.disposeFlutterOwned();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final resources = _resources;
    if (_phase == _StartupPhase.ready && resources != null) {
      return ClipTownApp(
        store: resources.store,
        stateMachine: resources.stateMachine,
        runtimeKind: resources.runtimeKind,
        disposeStateMachine: true,
        clipboardController: resources.clipboardController,
        desktopLifecycleHost: resources.desktopLifecycleHost,
        desktopBackgroundEnabled: resources.desktopBackgroundEnabled,
        desktopHotKeyEnabled: resources.desktopHotKeyEnabled,
      );
    }
    return _StartupSurface(
      failed: _phase == _StartupPhase.failed,
      message: _failureMessage,
      onRetry: _start,
    );
  }
}

class _StartupSurface extends StatelessWidget {
  const _StartupSurface({
    required this.failed,
    required this.message,
    required this.onRetry,
  });

  final bool failed;
  final String? message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClipTown',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff42d3ff),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xff030914),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  key: const ValueKey('cliptown-startup-surface'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.content_paste_go_outlined, size: 68),
                    const SizedBox(height: 18),
                    Text(
                      'ClipTown',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      failed
                          ? message ?? 'Encrypted startup failed safely.'
                          : 'Opening your encrypted clipboard vault…',
                      key: ValueKey(
                        failed
                            ? 'cliptown-startup-error'
                            : 'cliptown-startup-loading',
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    if (failed)
                      FilledButton.icon(
                        key: const ValueKey('cliptown-startup-retry'),
                        onPressed: () => unawaited(onRetry()),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      )
                    else
                      const SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 3),
                      ),
                    const SizedBox(height: 16),
                    const Text(
                      'Clipboard monitoring and sync stay off until the vault is ready.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UnavailableClipRepository implements ClipRepository {
  const _UnavailableClipRepository();

  @override
  Future<void> clear() =>
      Future<void>.error(const ClipRepositoryException('vault unavailable'));

  @override
  Future<List<ClipItem>> load() => Future<List<ClipItem>>.error(
    const ClipRepositoryException('vault unavailable'),
  );

  @override
  Future<void> save(List<ClipItem> clips) =>
      Future<void>.error(const ClipRepositoryException('vault unavailable'));
}
