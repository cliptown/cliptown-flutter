import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'clipboard/clipboard_controller.dart';
import 'clipboard/clipboard_service.dart';
import 'history/clip_item.dart';
import 'history/text_transform.dart';
import 'proximity/nearby_share_page.dart';
import 'src/clip_store.dart';

class ClipTownApp extends StatefulWidget {
  const ClipTownApp({
    super.key,
    this.store,
    this.clipboardController,
    this.desktopBackgroundEnabled = false,
    this.desktopHotKeyEnabled = false,
  });

  final ClipStore? store;
  final ClipboardController? clipboardController;
  final bool desktopBackgroundEnabled;
  final bool desktopHotKeyEnabled;

  @override
  State<ClipTownApp> createState() => _ClipTownAppState();
}

class _ClipTownAppState extends State<ClipTownApp> {
  late final ClipStore store = widget.store ?? ClipStore();
  late final bool ownsStore = widget.store == null;
  late final ClipboardController clipboardController =
      widget.clipboardController ??
      ClipboardController(store: store, service: MemoryClipClipboardService());
  late final bool ownsClipboardController = widget.clipboardController == null;

  @override
  void initState() {
    super.initState();
    if (!store.initialized) unawaited(store.initialize());
  }

  @override
  void dispose() {
    if (ownsClipboardController) clipboardController.dispose();
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
          seedColor: const Color(0xff42d3ff),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xff030914),
        cardTheme: const CardThemeData(
          color: Color(0xff0b1424),
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Color(0xff0b1424),
          border: OutlineInputBorder(),
        ),
        useMaterial3: true,
      ),
      home: ClipTownHome(
        store: store,
        clipboardController: clipboardController,
        desktopBackgroundEnabled: widget.desktopBackgroundEnabled,
        desktopHotKeyEnabled: widget.desktopHotKeyEnabled,
      ),
    );
  }
}

class ClipTownHome extends StatefulWidget {
  const ClipTownHome({
    super.key,
    required this.store,
    required this.clipboardController,
    this.desktopBackgroundEnabled = false,
    this.desktopHotKeyEnabled = false,
  });

  final ClipStore store;
  final ClipboardController clipboardController;
  final bool desktopBackgroundEnabled;
  final bool desktopHotKeyEnabled;

  @override
  State<ClipTownHome> createState() => _ClipTownHomeState();
}

class _ClipTownHomeState extends State<ClipTownHome> {
  ClipStore get store => widget.store;
  ClipboardController get clipboardController => widget.clipboardController;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ClipTown'),
        actions: <Widget>[
          IconButton(
            key: const Key('nearby-share'),
            tooltip: 'Nearby encrypted sharing',
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(builder: (_) => const NearbySharePage()),
            ),
            icon: const Icon(Icons.bluetooth),
          ),
          IconButton(
            key: const Key('privacy-settings'),
            tooltip: 'Privacy and capture settings',
            onPressed: _showPrivacySettings,
            icon: const Icon(Icons.shield_outlined),
          ),
          if (MediaQuery.sizeOf(context).width >= 600)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: ListenableBuilder(
                  listenable: store,
                  builder: (context, _) => Text(
                    _desktopStatus,
                    key: const Key('desktop-background-status'),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add-manual-clip'),
        onPressed: _addManualClip,
        icon: const Icon(Icons.add),
        label: const Text('New clip'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: ListenableBuilder(
                listenable: Listenable.merge(<Listenable>[
                  store,
                  clipboardController,
                ]),
                builder: (context, _) => _buildBody(context),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final clips = store.visibleClips;
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Your clipboard, private and useful.',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 6),
        Text(
          store.vaultLocked
              ? 'Encrypted history is locked. ClipTown refuses to capture or fall back to plaintext.'
              : 'History is encrypted locally. Likely secrets are skipped by default, and cloud sync remains off until reviewed key management is connected.',
          key: const Key('security-boundary-copy'),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 14),
        _StatusBanner(
          message:
              clipboardController.errorMessage ??
              store.statusMessage ??
              (store.captureEnabled
                  ? 'Capture ready'
                  : 'Capture paused — existing history remains searchable'),
          isError:
              store.vaultLocked || clipboardController.errorMessage != null,
        ),
        const SizedBox(height: 12),
        _buildSearchAndCapture(),
        const SizedBox(height: 10),
        _buildFilters(),
        if (store.queueLength > 0) ...<Widget>[
          const SizedBox(height: 10),
          _buildQueueBar(),
        ],
        const SizedBox(height: 12),
      ],
    );

    return CustomScrollView(
      key: const Key('clip-history-scroll'),
      slivers: <Widget>[
        SliverToBoxAdapter(child: header),
        if (clips.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyHistory(hasQuery: store.query.trim().isNotEmpty),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.only(bottom: 88),
            sliver: SliverList(
              key: const Key('clip-history-list'),
              delegate: SliverChildBuilderDelegate((context, index) {
                if (index.isOdd) return const SizedBox(height: 8);
                final clip = clips[index ~/ 2];
                return _ClipCard(
                  clip: clip,
                  queued: store.queuedIds.contains(clip.id),
                  onCopy: () => _run(() => clipboardController.copy(clip)),
                  onToggleQueued: () => store.toggleQueued(clip.id),
                  onTogglePinned: () => _run(() => store.togglePinned(clip.id)),
                  onAction: (action) => _handleClipAction(clip, action),
                );
              }, childCount: clips.length * 2 - 1),
            ),
          ),
      ],
    );
  }

  Widget _buildSearchAndCapture() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final search = TextField(
          key: const Key('clip-search'),
          onChanged: store.setQuery,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            labelText:
                'Search content, related text, tags, collections, and apps',
          ),
        );
        final capture = FilledButton.icon(
          key: const Key('capture-now'),
          onPressed: clipboardController.busy || store.vaultLocked
              ? null
              : () => _run(clipboardController.captureNow),
          icon: const Icon(Icons.content_paste_go),
          label: const Text('Capture now'),
        );
        if (constraints.maxWidth < 700) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[search, const SizedBox(height: 8), capture],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(child: search),
            const SizedBox(width: 10),
            capture,
          ],
        );
      },
    );
  }

  Widget _buildFilters() {
    final collectionValues = store.collections.toList()..sort();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        FilterChip(
          key: const Key('pinned-only'),
          label: const Text('Pinned only'),
          selected: store.pinnedOnly,
          onSelected: store.setPinnedOnly,
        ),
        DropdownButton<ClipKind?>(
          key: const Key('kind-filter'),
          value: store.kindFilter,
          hint: const Text('All types'),
          items: <DropdownMenuItem<ClipKind?>>[
            const DropdownMenuItem<ClipKind?>(
              value: null,
              child: Text('All types'),
            ),
            ...ClipKind.values.map(
              (kind) => DropdownMenuItem<ClipKind?>(
                value: kind,
                child: Text(kind.label),
              ),
            ),
          ],
          onChanged: store.setKindFilter,
        ),
        if (collectionValues.isNotEmpty)
          DropdownButton<String?>(
            key: const Key('collection-filter'),
            value: store.collectionFilter,
            hint: const Text('All collections'),
            items: <DropdownMenuItem<String?>>[
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('All collections'),
              ),
              ...collectionValues.map(
                (value) =>
                    DropdownMenuItem<String?>(value: value, child: Text(value)),
              ),
            ],
            onChanged: store.setCollectionFilter,
          ),
        const SizedBox(width: 4),
        Switch(
          key: const Key('capture-toggle'),
          value: store.captureEnabled,
          onChanged: store.vaultLocked
              ? null
              : (value) =>
                    _run(() => clipboardController.setCaptureEnabled(value)),
        ),
        Text(store.captureEnabled ? 'Capture on' : 'Capture off'),
      ],
    );
  }

  Widget _buildQueueBar() {
    return Card(
      color: const Color(0xff122342),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: <Widget>[
            const Icon(Icons.playlist_add_check),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${store.queueLength} item${store.queueLength == 1 ? '' : 's'} in the paste queue',
              ),
            ),
            FilledButton.tonalIcon(
              key: const Key('copy-next-queued'),
              onPressed: () => _run(clipboardController.copyNextQueued),
              icon: const Icon(Icons.skip_next),
              label: const Text('Copy next'),
            ),
          ],
        ),
      ),
    );
  }

  String get _desktopStatus {
    if (store.vaultLocked) return 'Vault locked • capture off';
    final pieces = <String>[
      widget.desktopBackgroundEnabled ? 'Tray active' : 'Foreground mode',
      if (widget.desktopHotKeyEnabled) '⌘/Ctrl+Shift+V ready',
      store.captureEnabled ? 'capture on' : 'capture paused',
    ];
    return pieces.join(' • ');
  }

  Future<void> _handleClipAction(ClipItem clip, _ClipAction action) async {
    switch (action) {
      case _ClipAction.rename:
        await _renameClip(clip);
      case _ClipAction.collection:
        await _assignCollection(clip);
      case _ClipAction.delete:
        await _run(() => store.delete(clip.id));
      case _ClipAction.plainText:
        await _run(
          () => clipboardController.copy(
            clip,
            transform: TextTransform.plainText,
          ),
        );
      case _ClipAction.trim:
        await _run(
          () => clipboardController.copy(
            clip,
            transform: TextTransform.trimWhitespace,
          ),
        );
      case _ClipAction.prettyJson:
        await _run(
          () => clipboardController.copy(
            clip,
            transform: TextTransform.prettyJson,
          ),
        );
      case _ClipAction.uppercase:
        await _run(
          () => clipboardController.copy(
            clip,
            transform: TextTransform.uppercase,
          ),
        );
      case _ClipAction.lowercase:
        await _run(
          () => clipboardController.copy(
            clip,
            transform: TextTransform.lowercase,
          ),
        );
      case _ClipAction.sortUniqueLines:
        await _run(
          () => clipboardController.copy(
            clip,
            transform: TextTransform.sortUniqueLines,
          ),
        );
    }
  }

  Future<void> _addManualClip() async {
    var value = '';
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a private local clip'),
        content: TextFormField(
          key: const Key('manual-clip-text'),
          autofocus: true,
          minLines: 3,
          maxLines: 10,
          onChanged: (newValue) => value = newValue,
          decoration: const InputDecoration(
            labelText: 'Text',
            helperText: 'Stored only in the encrypted local history.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('save-manual-clip'),
            onPressed: () => Navigator.pop(context, value),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (text != null && text.trim().isNotEmpty) {
      await _run(() => store.addText(text));
    }
  }

  Future<void> _renameClip(ClipItem clip) async {
    var value = clip.title;
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename clip'),
        content: TextFormField(
          key: const Key('rename-clip-title'),
          initialValue: value,
          autofocus: true,
          maxLength: 512,
          onChanged: (newValue) => value = newValue,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, value),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (title != null) await _run(() => store.rename(clip.id, title));
  }

  Future<void> _assignCollection(ClipItem clip) async {
    var value = clip.collection ?? '';
    final collection = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Collection'),
        content: TextFormField(
          key: const Key('clip-collection-name'),
          initialValue: value,
          autofocus: true,
          maxLength: 160,
          onChanged: (newValue) => value = newValue,
          decoration: const InputDecoration(
            labelText: 'Collection name',
            helperText: 'Leave empty to remove the current collection.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, value),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (collection != null) {
      await _run(() => store.setCollection(clip.id, collection));
    }
  }

  Future<void> _showPrivacySettings() async {
    var captureSensitive = store.captureLikelySensitive;
    var ignoredApplications = store.policy.ignoredApplications.join(', ');
    var historyLimit = store.policy.maxHistoryItems.toString();
    final result = await showDialog<_PrivacySettingsResult>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Privacy and capture'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SwitchListTile(
                  key: const Key('capture-sensitive-toggle'),
                  contentPadding: EdgeInsets.zero,
                  value: captureSensitive,
                  onChanged: (value) =>
                      setDialogState(() => captureSensitive = value),
                  title: const Text('Keep likely sensitive text'),
                  subtitle: const Text(
                    'Off by default. Private keys, tokens, card numbers, and one-time-code-shaped values are otherwise rejected before persistence.',
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  key: const Key('ignored-applications'),
                  initialValue: ignoredApplications,
                  onChanged: (value) => ignoredApplications = value,
                  decoration: const InputDecoration(
                    labelText: 'Excluded application identifiers',
                    helperText:
                        'Comma-separated. Enforced when a native source-app adapter supplies an identifier.',
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('history-item-limit'),
                  initialValue: historyLimit,
                  keyboardType: TextInputType.number,
                  onChanged: (value) => historyLimit = value,
                  decoration: const InputDecoration(
                    labelText: 'Saved unpinned items',
                    helperText:
                        'Between 1 and 100,000. Pinned clips are retained separately.',
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Retention: ${store.policy.retention.inDays} days • Unpinned limit: ${store.policy.maxHistoryItems} • Per-item limit: ${store.policy.maxItemBytes ~/ (1024 * 1024)} MiB',
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const Key('clear-unpinned'),
              onPressed: () => Navigator.pop(
                context,
                const _PrivacySettingsResult(clearUnpinned: true),
              ),
              child: const Text('Clear unpinned'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                _PrivacySettingsResult(
                  captureSensitive: captureSensitive,
                  ignoredApplications: ignoredApplications,
                  historyLimit: int.tryParse(historyLimit),
                ),
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    if (result.clearUnpinned) {
      await _run(store.clearUnpinned);
      return;
    }
    store.setCaptureLikelySensitive(result.captureSensitive ?? false);
    store.setIgnoredApplications(
      (result.ignoredApplications ?? '')
          .split(',')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toSet(),
    );
    if (result.historyLimit case final historyLimit?) {
      await _run(() => store.setHistoryLimit(historyLimit));
    }
  }

  Future<void> _run(FutureOr<Object?> Function() action) async {
    try {
      await action();
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The operation failed without exposing clipboard data.',
          ),
        ),
      );
    }
  }
}

class _ClipCard extends StatelessWidget {
  const _ClipCard({
    required this.clip,
    required this.queued,
    required this.onCopy,
    required this.onToggleQueued,
    required this.onTogglePinned,
    required this.onAction,
  });

  final ClipItem clip;
  final bool queued;
  final VoidCallback onCopy;
  final VoidCallback onToggleQueued;
  final VoidCallback onTogglePinned;
  final ValueChanged<_ClipAction> onAction;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final details = Column(
              key: Key('clip-${clip.id}'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  clip.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  clip.summary,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: <Widget>[
                    _MetaChip(label: clip.kind.label),
                    if (clip.collection case final collection?)
                      _MetaChip(label: collection),
                    if (clip.sourceApplication case final source?)
                      _MetaChip(label: source),
                    ...clip.tags.map((tag) => _MetaChip(label: '#$tag')),
                  ],
                ),
              ],
            );
            final actions = <Widget>[
              IconButton(
                key: Key('copy-${clip.id}'),
                tooltip: 'Copy ${clip.title}',
                onPressed: onCopy,
                icon: const Icon(Icons.copy),
              ),
              IconButton(
                key: Key('queue-${clip.id}'),
                tooltip: queued
                    ? 'Remove from paste queue'
                    : 'Add to paste queue',
                onPressed: onToggleQueued,
                icon: Icon(queued ? Icons.playlist_remove : Icons.playlist_add),
              ),
              IconButton(
                key: Key('pin-${clip.id}'),
                tooltip: clip.pinned
                    ? 'Unpin ${clip.title}'
                    : 'Pin ${clip.title}',
                onPressed: onTogglePinned,
                icon: Icon(
                  clip.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                ),
              ),
              PopupMenuButton<_ClipAction>(
                key: Key('actions-${clip.id}'),
                tooltip: 'More actions',
                onSelected: onAction,
                itemBuilder: (context) => <PopupMenuEntry<_ClipAction>>[
                  const PopupMenuItem(
                    value: _ClipAction.rename,
                    child: Text('Rename'),
                  ),
                  const PopupMenuItem(
                    value: _ClipAction.collection,
                    child: Text('Move to collection'),
                  ),
                  if (clip.text != null) ...<PopupMenuEntry<_ClipAction>>[
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: _ClipAction.plainText,
                      child: Text('Copy as plain text'),
                    ),
                    const PopupMenuItem(
                      value: _ClipAction.trim,
                      child: Text('Trim and copy'),
                    ),
                    const PopupMenuItem(
                      value: _ClipAction.prettyJson,
                      child: Text('Pretty-print JSON and copy'),
                    ),
                    const PopupMenuItem(
                      value: _ClipAction.uppercase,
                      child: Text('Uppercase and copy'),
                    ),
                    const PopupMenuItem(
                      value: _ClipAction.lowercase,
                      child: Text('Lowercase and copy'),
                    ),
                    const PopupMenuItem(
                      value: _ClipAction.sortUniqueLines,
                      child: Text('Sort unique lines and copy'),
                    ),
                  ],
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: _ClipAction.delete,
                    child: Text('Delete'),
                  ),
                ],
              ),
            ];
            if (constraints.maxWidth < 560) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _ClipPreview(clip: clip),
                      const SizedBox(width: 12),
                      Expanded(child: details),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(spacing: 2, children: actions),
                  ),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _ClipPreview(clip: clip),
                const SizedBox(width: 12),
                Expanded(child: details),
                ...actions,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ClipPreview extends StatelessWidget {
  const _ClipPreview({required this.clip});

  final ClipItem clip;

  @override
  Widget build(BuildContext context) {
    if (clip.kind == ClipKind.image && clip.dataBase64 != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          base64Decode(clip.dataBase64!),
          width: 56,
          height: 56,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const _KindAvatar(label: 'I'),
        ),
      );
    }
    return _KindAvatar(label: clip.kind.label.characters.first);
  }
}

class _KindAvatar extends StatelessWidget {
  const _KindAvatar({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => CircleAvatar(child: Text(label));
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall),
    ),
  );
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: isError ? const Color(0xff4a1721) : const Color(0xff10243a),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        children: <Widget>[
          Icon(isError ? Icons.lock : Icons.privacy_tip_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, key: const Key('capture-status-message')),
          ),
        ],
      ),
    ),
  );
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory({required this.hasQuery});

  final bool hasQuery;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(Icons.content_paste_search, size: 52),
        const SizedBox(height: 12),
        Text(
          hasQuery
              ? 'No clips match this search.'
              : 'No clipboard history yet.',
          key: const Key('empty-history'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          hasQuery
              ? 'Try a different search or clear a filter.'
              : 'Copy something, use Capture now, or add a local clip.',
        ),
      ],
    ),
  );
}

enum _ClipAction {
  rename,
  collection,
  plainText,
  trim,
  prettyJson,
  uppercase,
  lowercase,
  sortUniqueLines,
  delete,
}

class _PrivacySettingsResult {
  const _PrivacySettingsResult({
    this.captureSensitive,
    this.ignoredApplications,
    this.historyLimit,
    this.clearUnpinned = false,
  });

  final bool? captureSensitive;
  final String? ignoredApplications;
  final int? historyLimit;
  final bool clearUnpinned;
}
