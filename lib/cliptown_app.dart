import 'package:flutter/material.dart';

import 'src/clip_store.dart';

class ClipTownApp extends StatefulWidget {
  const ClipTownApp({super.key, this.store});

  final ClipStore? store;

  @override
  State<ClipTownApp> createState() => _ClipTownAppState();
}

class _ClipTownAppState extends State<ClipTownApp> {
  late final ClipStore store = widget.store ?? ClipStore();
  late final bool ownsStore = widget.store == null;

  @override
  void dispose() {
    if (ownsStore) store.dispose();
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
      home: ClipTownHome(store: store),
    );
  }
}

class ClipTownHome extends StatelessWidget {
  const ClipTownHome({super.key, required this.store});

  final ClipStore store;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ClipTown'),
        actions: const <Widget>[
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: Center(child: Text('Local preview • sync disconnected')),
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
