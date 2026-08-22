import 'package:flutter/material.dart';

import 'src/clip_store.dart';
import 'state/app_state_machine.dart';

class ClipTownApp extends StatefulWidget {
  const ClipTownApp({
    super.key,
    this.store,
    this.stateMachine,
    this.runtimeKind = AppRuntimeKind.mobile,
    this.disposeStateMachine = false,
    this.desktopBackgroundEnabled = false,
  });

  final ClipStore? store;
  final AppStateMachine? stateMachine;
  final AppRuntimeKind runtimeKind;
  final bool disposeStateMachine;
  final bool desktopBackgroundEnabled;

  @override
  State<ClipTownApp> createState() => _ClipTownAppState();
}

class _ClipTownAppState extends State<ClipTownApp> with WidgetsBindingObserver {
  late final ClipStore store = widget.store ?? ClipStore();
  late final bool ownsStore = widget.store == null;
  late final AppStateMachine stateMachine =
      widget.stateMachine ?? AppStateMachine.signedOut(widget.runtimeKind);
  late final bool ownsStateMachine =
      widget.stateMachine == null || widget.disposeStateMachine;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    final event = appEventForFlutterLifecycle(
      runtime: stateMachine.state.runtime,
      lifecycleState: lifecycleState,
    );
    if (event != null) stateMachine.dispatch(event);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (ownsStore) store.dispose();
    if (ownsStateMachine) stateMachine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ClipTown',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff2f6bff),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xff030914),
        useMaterial3: true,
      ),
      home: ClipTownHome(
        store: store,
        stateMachine: stateMachine,
        desktopBackgroundEnabled: widget.desktopBackgroundEnabled,
      ),
    );
  }
}

/// Translates Flutter's platform lifecycle into the app's finite event alphabet.
///
/// Desktop window/tray transitions are owned by [DesktopLifecycleController],
/// so Flutter lifecycle notifications are intentionally ignored there. Mobile
/// inactive, hidden, and paused states all fail closed through the same formal
/// background transition. A detached engine starts the controlled shutdown
/// path.
AppEvent? appEventForFlutterLifecycle({
  required AppRuntimeKind runtime,
  required AppLifecycleState lifecycleState,
}) {
  if (runtime == AppRuntimeKind.desktop) return null;

  return switch (lifecycleState) {
    AppLifecycleState.resumed => AppEvent.foregroundRequested,
    AppLifecycleState.inactive ||
    AppLifecycleState.hidden ||
    AppLifecycleState.paused => AppEvent.backgroundRequested,
    AppLifecycleState.detached => AppEvent.shutdownRequested,
  };
}

class ClipTownHome extends StatelessWidget {
  const ClipTownHome({
    super.key,
    required this.store,
    required this.stateMachine,
    this.desktopBackgroundEnabled = false,
  });

  final ClipStore store;
  final AppStateMachine stateMachine;
  final bool desktopBackgroundEnabled;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ClipTown'),
        actions: <Widget>[
          ListenableBuilder(
            listenable: stateMachine,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Text(
                      desktopBackgroundEnabled
                          ? 'Tray active • close keeps ClipTown running'
                          : 'Local preview • sync disconnected',
                      key: const Key('desktop-background-status'),
                    ),
                    Text(
                      stateMachine.statusLabel,
                      key: const Key('formal-state-status'),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    'Your clipboard has a memory.',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Search and pin local encrypted clip previews. Cloud and peer synchronization remain disabled until authentication and key management are configured.',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    key: const Key('clip-search'),
                    onChanged: store.setQuery,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      labelText: 'Search clips',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ListenableBuilder(
                    listenable: store,
                    builder: (context, _) => FilterChip(
                      key: const Key('pinned-only'),
                      label: const Text('Pinned only'),
                      selected: store.pinnedOnly,
                      onSelected: store.setPinnedOnly,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: store,
                      builder: (context, _) {
                        final clips = store.visibleClips;
                        if (clips.isEmpty) {
                          return const Center(
                            child: Text('No clips match this search.'),
                          );
                        }
                        return ListView.separated(
                          itemCount: clips.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) => _ClipCard(
                            clip: clips[index],
                            onTogglePinned: () =>
                                store.togglePinned(clips[index].id),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ClipCard extends StatelessWidget {
  const _ClipCard({required this.clip, required this.onTogglePinned});

  final ClipPreview clip;
  final VoidCallback onTogglePinned;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        key: Key('clip-${clip.id}'),
        leading: CircleAvatar(child: Text(clip.kind.characters.first)),
        title: Text(clip.title),
        subtitle: Text(
          clip.detail,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          key: Key('pin-${clip.id}'),
          tooltip: clip.pinned ? 'Unpin ${clip.title}' : 'Pin ${clip.title}',
          onPressed: onTogglePinned,
          icon: Icon(clip.pinned ? Icons.push_pin : Icons.push_pin_outlined),
        ),
      ),
    );
  }
}
