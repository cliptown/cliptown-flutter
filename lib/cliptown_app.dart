import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'clipboard/clipboard_controller.dart';
import 'clipboard/clipboard_service.dart';
import 'desktop/desktop_lifecycle_host.dart';
import 'desktop/desktop_shell.dart';
import 'desktop/desktop_shortcuts.dart';
import 'history/clip_content_preview.dart';
import 'history/clip_formatting.dart';
import 'history/clip_item.dart';
import 'history/text_transform.dart';
import 'proximity/nearby_share_page.dart';
import 'src/clip_store.dart';
import 'state/app_state_machine.dart';
import 'ui/tooltip_accelerator.dart';

class ClipTownApp extends StatefulWidget {
  const ClipTownApp({
    super.key,
    this.store,
    this.stateMachine,
    this.runtimeKind = AppRuntimeKind.mobile,
    this.disposeStateMachine = false,
    this.clipboardController,
    this.desktopLifecycleHost,
    this.desktopShell,
    this.desktopBackgroundEnabled = false,
    this.desktopHotKeyEnabled = false,
  });

  final ClipStore? store;
  final AppStateMachine? stateMachine;
  final AppRuntimeKind runtimeKind;
  final bool disposeStateMachine;
  final ClipboardController? clipboardController;
  final DesktopLifecycleHost? desktopLifecycleHost;

  /// Defaults to [desktopLifecycleHost]; tests inject a fake shell.
  final DesktopShell? desktopShell;
  final bool desktopBackgroundEnabled;
  final bool desktopHotKeyEnabled;

  @override
  State<ClipTownApp> createState() => _ClipTownAppState();
}

class _ClipTownAppState extends State<ClipTownApp> with WidgetsBindingObserver {
  late final ClipStore store = widget.store ?? ClipStore();
  late final bool ownsStore = widget.store == null;
  late final AppStateMachine stateMachine =
      widget.stateMachine ??
      widget.clipboardController?.stateMachine ??
      widget.desktopLifecycleHost?.controller.stateMachine ??
      _newStateMachine();
  late final bool ownsStateMachine =
      (widget.stateMachine == null &&
          widget.clipboardController == null &&
          widget.desktopLifecycleHost == null) ||
      (widget.stateMachine != null && widget.disposeStateMachine);
  late final ClipboardController clipboardController =
      widget.clipboardController ??
      ClipboardController(
        store: store,
        service: MemoryClipClipboardService(),
        stateMachine: stateMachine,
      );
  late final bool ownsClipboardController = widget.clipboardController == null;

  AppStateMachine _newStateMachine() {
    if (!store.initialized) return AppStateMachine.initial(widget.runtimeKind);
    return store.vaultLocked
        ? AppStateMachine.vaultUnavailable(widget.runtimeKind)
        : AppStateMachine.localReady(
            widget.runtimeKind,
            captureRequested: store.captureEnabled,
          );
  }

  @override
  void initState() {
    super.initState();
    _validateSingleTransitionAuthority();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  void _validateSingleTransitionAuthority() {
    final suppliedAuthorities = <AppStateMachine?>[
      widget.stateMachine,
      widget.clipboardController?.stateMachine,
      widget.desktopLifecycleHost?.controller.stateMachine,
    ].whereType<AppStateMachine>();
    if (suppliedAuthorities.any((authority) => authority != stateMachine)) {
      throw StateError(
        'ClipTown requires one shared app state machine for UI, clipboard, and desktop lifecycle effects',
      );
    }
  }

  Future<void> _initialize() async {
    if (!store.initialized) await store.initialize();
    if (!mounted) return;
    if (widget.stateMachine == null &&
        widget.clipboardController == null &&
        widget.desktopLifecycleHost == null &&
        stateMachine.state.lifecycle == AppLifecyclePhase.starting) {
      stateMachine.dispatch(
        store.vaultLocked
            ? AppEvent.bootVaultUnavailable
            : store.captureEnabled
            ? AppEvent.bootLocalReadyCaptureOn
            : AppEvent.bootLocalReadyCaptureOff,
      );
    }
    await clipboardController.initialize();
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
    if (ownsClipboardController) clipboardController.dispose();
    if (ownsStateMachine) stateMachine.dispose();
    if (ownsStore) store.dispose();
    unawaited(widget.desktopLifecycleHost?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ClipTown',
      builder: (context, child) =>
          TooltipAccelerator(child: child ?? const SizedBox.shrink()),
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
        stateMachine: stateMachine,
        clipboardController: clipboardController,
        desktopShell: widget.desktopShell ?? widget.desktopLifecycleHost,
        desktopBackgroundEnabled: widget.desktopBackgroundEnabled,
        desktopHotKeyEnabled: widget.desktopHotKeyEnabled,
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

class ClipTownHome extends StatefulWidget {
  const ClipTownHome({
    super.key,
    required this.store,
    required this.stateMachine,
    required this.clipboardController,
    this.desktopShell,
    this.desktopBackgroundEnabled = false,
    this.desktopHotKeyEnabled = false,
  });

  final ClipStore store;
  final AppStateMachine stateMachine;
  final ClipboardController clipboardController;
  final DesktopShell? desktopShell;
  final bool desktopBackgroundEnabled;
  final bool desktopHotKeyEnabled;

  @override
  State<ClipTownHome> createState() => _ClipTownHomeState();
}

class _ClipTownHomeState extends State<ClipTownHome> {
  ClipStore get store => widget.store;
  AppStateMachine get stateMachine => widget.stateMachine;
  ClipboardController get clipboardController => widget.clipboardController;
  DesktopShell? get desktopShell => widget.desktopShell;

  final FocusNode _rootFocus = FocusNode(debugLabel: 'clip-home');
  final FocusNode _searchFocus = FocusNode(debugLabel: 'clip-search');
  final TextEditingController _searchController = TextEditingController();
  final GlobalKey _selectedRowKey = GlobalKey(debugLabel: 'selected-clip');
  int _selectedIndex = 0;
  List<ClipItem> _visibleClips = const <ClipItem>[];

  bool get _isApple =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    _attachShell(desktopShell);
    store.addListener(_syncTrayMenu);
    stateMachine.addListener(_syncTrayMenu);
    _syncTrayMenu();
  }

  @override
  void didUpdateWidget(ClipTownHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.desktopShell != desktopShell) {
      oldWidget.desktopShell?.summonCount.removeListener(_onSummoned);
      _attachShell(desktopShell);
      _syncTrayMenu();
    }
    if (oldWidget.store != store) {
      oldWidget.store.removeListener(_syncTrayMenu);
      store.addListener(_syncTrayMenu);
    }
    if (oldWidget.stateMachine != stateMachine) {
      oldWidget.stateMachine.removeListener(_syncTrayMenu);
      stateMachine.addListener(_syncTrayMenu);
    }
  }

  @override
  void dispose() {
    desktopShell?.summonCount.removeListener(_onSummoned);
    store.removeListener(_syncTrayMenu);
    stateMachine.removeListener(_syncTrayMenu);
    _rootFocus.dispose();
    _searchFocus.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _attachShell(DesktopShell? shell) {
    if (shell == null) return;
    shell.summonCount.addListener(_onSummoned);
    shell.setTrayHandlers(
      DesktopTrayHandlers(
        onRecentClipSelected: _copyFromTray,
        onToggleCapture: () => _run(
          () => clipboardController.setCaptureEnabled(
            !stateMachine.state.captureRequested,
          ),
        ),
      ),
    );
  }

  /// Summoned via the global shortcut or tray: start a fresh keyboard search.
  void _onSummoned() {
    if (!mounted) return;
    setState(() => _selectedIndex = 0);
    _searchFocus.requestFocus();
    _searchController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _searchController.text.length,
    );
  }

  bool _traySyncScheduled = false;

  /// Coalesces bursts of store/state notifications into one tray update.
  void _syncTrayMenu() {
    if (desktopShell == null || _traySyncScheduled) return;
    _traySyncScheduled = true;
    scheduleMicrotask(() {
      _traySyncScheduled = false;
      if (mounted) _pushTrayMenu();
    });
  }

  void _pushTrayMenu() {
    final shell = desktopShell;
    if (shell == null) return;
    final state = stateMachine.state;
    final recent = state.permitsLocalWork
        ? store.mostRecent(trayRecentClipLimit)
        : const <ClipItem>[];
    shell.updateTrayMenu(
      DesktopTrayMenuModel.fromClips(
        recent,
        captureOn: state.captureRequested,
        captureAvailable: state.permitsLocalWork || state.captureRequested,
      ),
    );
  }

  void _copyFromTray(String id) {
    final clip = store.findById(id);
    if (clip == null) return;
    unawaited(_run(() => clipboardController.copy(clip)));
  }

  ClipItem? get _selectedClip => _visibleClips.isEmpty
      ? null
      : _visibleClips[_selectedIndex.clamp(0, _visibleClips.length - 1)];

  void _moveSelection(int delta) {
    if (_visibleClips.isEmpty) return;
    final next = (_selectedIndex + delta).clamp(0, _visibleClips.length - 1);
    if (next == _selectedIndex) return;
    setState(() => _selectedIndex = next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final rowContext = _selectedRowKey.currentContext;
      if (rowContext == null || !rowContext.mounted) return;
      Scrollable.ensureVisible(
        rowContext,
        duration: const Duration(milliseconds: 90),
        alignmentPolicy: delta > 0
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    });
  }

  /// Copy, then get out of the way so the user can paste where they were.
  Future<void> _copyAndDismiss(ClipItem clip) async {
    if (await _run(() => clipboardController.copy(clip))) {
      await desktopShell?.dismiss();
    }
  }

  void _copySelected() {
    final clip = _selectedClip;
    if (clip != null) unawaited(_copyAndDismiss(clip));
  }

  void _copyAt(int index) {
    if (index < _visibleClips.length) {
      unawaited(_copyAndDismiss(_visibleClips[index]));
    }
  }

  void _onEscape() {
    if (_searchController.text.isNotEmpty) {
      _searchController.clear();
      _onQueryChanged('');
      return;
    }
    unawaited(desktopShell?.dismiss());
  }

  void _onQueryChanged(String value) {
    store.setQuery(value);
    setState(() => _selectedIndex = 0);
  }

  /// Arrow/Page/Return drive the clip picker only while the search field (or
  /// nothing more specific) has focus. When a button, chip or menu is focused
  /// those keys fall through, so keyboard users can still activate controls.
  bool get _pickerHasFocus {
    final focused = FocusManager.instance.primaryFocus;
    return focused == null || focused == _searchFocus || focused == _rootFocus;
  }

  /// Option/Alt+Backspace deletes a word while there is search text to edit;
  /// only an empty (or unfocused) search turns it into "delete selected clip".
  bool get _deleteShortcutApplies =>
      !(_searchFocus.hasFocus && _searchController.text.isNotEmpty);

  List<_KeyBinding> get _keyBindings {
    final quickCopyKeys = <LogicalKeyboardKey>[
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];
    bool picker() => _pickerHasFocus;
    return <_KeyBinding>[
      _KeyBinding(
        const SingleActivator(LogicalKeyboardKey.arrowDown),
        () => _moveSelection(1),
        when: picker,
      ),
      _KeyBinding(
        const SingleActivator(LogicalKeyboardKey.arrowUp),
        () => _moveSelection(-1),
        when: picker,
      ),
      _KeyBinding(
        const SingleActivator(LogicalKeyboardKey.pageDown),
        () => _moveSelection(5),
        when: picker,
      ),
      _KeyBinding(
        const SingleActivator(LogicalKeyboardKey.pageUp),
        () => _moveSelection(-5),
        when: picker,
      ),
      _KeyBinding(
        const SingleActivator(LogicalKeyboardKey.enter),
        _copySelected,
        when: picker,
      ),
      _KeyBinding(
        const SingleActivator(LogicalKeyboardKey.numpadEnter),
        _copySelected,
        when: picker,
      ),
      _KeyBinding(const SingleActivator(LogicalKeyboardKey.escape), _onEscape),
      _KeyBinding(dismissActivator, () => unawaited(desktopShell?.dismiss())),
      _KeyBinding(
        const SingleActivator(LogicalKeyboardKey.keyP, alt: true),
        () {
          final clip = _selectedClip;
          if (clip != null) _runLocal(() => store.togglePinned(clip.id));
        },
      ),
      _KeyBinding(
        const SingleActivator(LogicalKeyboardKey.backspace, alt: true),
        () {
          final clip = _selectedClip;
          if (clip != null) unawaited(_deleteWithUndo(clip));
        },
        when: () => _deleteShortcutApplies,
      ),
      _KeyBinding(
        SingleActivator(
          LogicalKeyboardKey.keyF,
          meta: _isApple,
          control: !_isApple,
        ),
        _searchFocus.requestFocus,
      ),
      for (final (index, key) in quickCopyKeys.indexed)
        _KeyBinding(
          SingleActivator(key, meta: _isApple, control: !_isApple),
          () => _copyAt(index),
        ),
    ];
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    for (final binding in _keyBindings) {
      if (binding.activator.accepts(event, HardwareKeyboard.instance) &&
          (binding.when?.call() ?? true)) {
        binding.onKey();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// Deletion is the one destructive action reachable from the keyboard, so
  /// it is always undoable.
  Future<void> _deleteWithUndo(ClipItem clip) async {
    final deleted = await _runLocal(() => store.delete(clip.id));
    if (!deleted || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const Key('clip-deleted-snackbar'),
          content: Text('Deleted "${clip.title}"'),
          action: SnackBarAction(
            key: const Key('undo-delete'),
            label: 'Undo',
            onPressed: () => _runLocal(() => store.restore(clip)),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _rootFocus,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const _AppTitle(),
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
                  listenable: Listenable.merge(<Listenable>[
                    store,
                    stateMachine,
                  ]),
                  builder: (context, _) => ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        Text(
                          _desktopStatus,
                          key: const Key('desktop-background-status'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        Text(
                          stateMachine.statusLabel,
                          key: const Key('formal-state-status'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: ListenableBuilder(
        listenable: stateMachine,
        builder: (context, _) => FloatingActionButton.extended(
          key: const Key('add-manual-clip'),
          tooltip:
              'Type or paste a clip by hand. It is stored only in your '
              'encrypted local history.',
          onPressed: stateMachine.state.permitsLocalWork
              ? _addManualClip
              : null,
          icon: const Icon(Icons.add),
          label: const Text('New clip'),
        ),
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
                  stateMachine,
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
    final localWorkAllowed = stateMachine.state.permitsLocalWork;
    final clips = localWorkAllowed ? store.visibleClips : const <ClipItem>[];
    _visibleClips = clips;
    final selectedIndex = clips.isEmpty
        ? -1
        : _selectedIndex.clamp(0, clips.length - 1);
    final now = DateTime.now();
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Your clipboard, private and useful.',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 6),
        Text(
          !localWorkAllowed
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
              (stateMachine.state.permitsCaptureWork
                  ? 'Capture ready'
                  : 'Capture paused — existing history remains searchable'),
          isError:
              !localWorkAllowed || clipboardController.errorMessage != null,
        ),
        const SizedBox(height: 12),
        _buildSearch(),
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
                final clipIndex = index ~/ 2;
                final clip = clips[clipIndex];
                final selected = clipIndex == selectedIndex;
                return _ClipCard(
                  key: selected ? _selectedRowKey : ValueKey(clip.id),
                  clip: clip,
                  now: now,
                  selected: selected,
                  quickCopyLabel: clipIndex < 9
                      ? '${_isApple ? '⌘' : 'Ctrl+'}${clipIndex + 1}'
                      : null,
                  onSelect: () => setState(() => _selectedIndex = clipIndex),
                  queued: store.queuedIds.contains(clip.id),
                  onCopy: () => _run(() => clipboardController.copy(clip)),
                  onToggleQueued: () =>
                      _runLocal(() => store.toggleQueued(clip.id)),
                  onTogglePinned: () =>
                      _runLocal(() => store.togglePinned(clip.id)),
                  onAction: (action) => _handleClipAction(clip, action),
                );
              }, childCount: clips.length * 2 - 1),
            ),
          ),
      ],
    );
  }

  Widget _buildSearch() {
    return TextField(
      key: const Key('clip-search'),
      controller: _searchController,
      focusNode: _searchFocus,
      autofocus: desktopShell != null,
      onChanged: _onQueryChanged,
      decoration: const InputDecoration(
        prefixIcon: Tooltip(
          message:
              'Searches text, titles, tags, collections, source apps and '
              'related meaning. Esc clears.',
          child: Icon(Icons.search),
        ),
        labelText: 'Search content, related text, tags, collections, and apps',
        helperText: '↑ ↓ to select • Return copies • Esc clears or hides',
      ),
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
          tooltip: store.pinnedOnly
              ? 'Showing pinned clips only. Click to show everything.'
              : 'Show only pinned clips. Pinned clips are never pruned by the '
                    'history limit.',
          selected: store.pinnedOnly,
          onSelected: store.setPinnedOnly,
        ),
        Tooltip(
          message: 'Filter history by content type',
          child: DropdownButton<ClipKind?>(
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
        ),
        if (collectionValues.isNotEmpty)
          Tooltip(
            message: 'Filter history by collection',
            child: DropdownButton<String?>(
              key: const Key('collection-filter'),
              value: store.collectionFilter,
              hint: const Text('All collections'),
              items: <DropdownMenuItem<String?>>[
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('All collections'),
                ),
                ...collectionValues.map(
                  (value) => DropdownMenuItem<String?>(
                    value: value,
                    child: Text(value),
                  ),
                ),
              ],
              onChanged: store.setCollectionFilter,
            ),
          ),
        const SizedBox(width: 4),
        Tooltip(
          message: stateMachine.state.captureRequested
              ? 'Capture is on: everything you copy is saved to your encrypted '
                    'history (likely secrets are skipped). Switch off to pause.'
              : 'Capture is paused: nothing you copy is saved. Existing history '
                    'stays searchable. Switch on to resume.',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Switch(
                key: const Key('capture-toggle'),
                value: stateMachine.state.captureRequested,
                onChanged:
                    !stateMachine.state.permitsLocalWork &&
                        !stateMachine.state.captureRequested
                    ? null
                    : (value) => _run(
                        () => clipboardController.setCaptureEnabled(value),
                      ),
              ),
              Text(
                stateMachine.state.captureRequested
                    ? 'Capture on'
                    : 'Capture off',
              ),
            ],
          ),
        ),
        _buildSaveClipboardButton(),
      ],
    );
  }

  /// Always visible next to the capture controls (not the search row, where it
  /// read as a search action). Greyed out whenever saving would do nothing; the
  /// tooltip says what it does and why it is unavailable.
  Widget _buildSaveClipboardButton() {
    final status = clipboardController.saveStatus;
    final saved = status.availability == ClipboardSaveAvailability.alreadySaved;
    return Tooltip(
      key: const Key('capture-now-tooltip'),
      message: status.tooltip,
      child: OutlinedButton.icon(
        key: const Key('capture-now'),
        onPressed: status.enabled
            ? () => _run(clipboardController.captureNow)
            : null,
        icon: Icon(
          saved ? Icons.check_circle_outline : Icons.content_paste_go,
          size: 18,
        ),
        label: const Text('Save clipboard now'),
      ),
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
            Tooltip(
              message:
                  'Copy the next queued clip to the clipboard (in the order '
                  'you queued them), then paste it wherever you need it.',
              child: FilledButton.tonalIcon(
                key: const Key('copy-next-queued'),
                onPressed: () => _run(clipboardController.copyNextQueued),
                icon: const Icon(Icons.skip_next),
                label: const Text('Copy next'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _desktopStatus {
    if (!stateMachine.state.permitsLocalWork) {
      return 'Vault ${stateMachine.state.vault.name} • capture off';
    }
    final pieces = <String>[
      widget.desktopBackgroundEnabled ? 'Tray active' : 'Foreground mode',
      if (widget.desktopHotKeyEnabled)
        '${summonShortcutLabel(isMacOS: _isApple)} opens • ${dismissShortcutLabel(isMacOS: _isApple)} hides',
      if (widget.desktopBackgroundEnabled && !widget.desktopHotKeyEnabled)
        '${summonShortcutLabel(isMacOS: _isApple)} shortcut unavailable',
      stateMachine.state.captureRequested ? 'capture on' : 'capture paused',
    ];
    return pieces.join(' • ');
  }

  Future<void> _handleClipAction(ClipItem clip, _ClipAction action) async {
    switch (action) {
      case _ClipAction.rename:
        await _renameClip(clip);
      case _ClipAction.editText:
        await _editClipText(clip);
      case _ClipAction.tags:
        await _editTags(clip);
      case _ClipAction.collection:
        await _assignCollection(clip);
      case _ClipAction.delete:
        await _deleteWithUndo(clip);
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
      await _runLocal(() => store.addText(text));
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
    if (title != null) await _runLocal(() => store.rename(clip.id, title));
  }

  Future<void> _editClipText(ClipItem clip) async {
    var value = clip.text ?? '';
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit clip'),
        content: SizedBox(
          width: 560,
          child: TextFormField(
            key: const Key('edit-clip-text'),
            initialValue: value,
            autofocus: true,
            minLines: 4,
            maxLines: 16,
            onChanged: (newValue) => value = newValue,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('save-edited-clip'),
            onPressed: () => Navigator.pop(context, value),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (text != null && text.trim().isNotEmpty) {
      await _runLocal(() => store.editText(clip.id, text));
    }
  }

  Future<void> _editTags(ClipItem clip) async {
    var value = (clip.tags.toList()..sort()).join(', ');
    final tags = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tags'),
        content: TextFormField(
          key: const Key('clip-tags'),
          initialValue: value,
          autofocus: true,
          onChanged: (newValue) => value = newValue,
          decoration: const InputDecoration(
            labelText: 'Tags',
            helperText: 'Comma-separated. Tags are searchable.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('save-clip-tags'),
            onPressed: () => Navigator.pop(context, value),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (tags == null) return;
    await _runLocal(
      () => store.setTags(
        clip.id,
        tags.split(',').map((tag) => tag.trim().replaceFirst('#', '')).toSet(),
      ),
    );
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
      await _runLocal(() => store.setCollection(clip.id, collection));
    }
  }

  Future<void> _showPrivacySettings() async {
    final launchAtLogin = desktopShell?.launchAtLogin;
    bool? openAtLogin;
    if (launchAtLogin != null) {
      try {
        openAtLogin = await launchAtLogin.isEnabled();
      } on Object {
        openAtLogin = null;
      }
      if (!mounted) return;
    }
    final initialOpenAtLogin = openAtLogin;
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
                if (openAtLogin != null)
                  SwitchListTile(
                    key: const Key('open-at-login-toggle'),
                    contentPadding: EdgeInsets.zero,
                    value: openAtLogin ?? false,
                    onChanged: (value) =>
                        setDialogState(() => openAtLogin = value),
                    title: const Text('Open ClipTown at login'),
                    subtitle: const Text(
                      'Starts quietly in the tray so history is captured from the moment you log in.',
                    ),
                  ),
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
    if ((launchAtLogin, openAtLogin) case (
      final login?,
      final enabled?,
    ) when enabled != initialOpenAtLogin && !result.clearUnpinned) {
      await _run(() => login.setEnabled(enabled));
    }
    if (result.clearUnpinned) {
      await _runLocal(store.clearUnpinned);
      return;
    }
    await _runLocal(() async {
      store.setCaptureLikelySensitive(result.captureSensitive ?? false);
      store.setIgnoredApplications(
        (result.ignoredApplications ?? '')
            .split(',')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toSet(),
      );
      if (result.historyLimit case final historyLimit?) {
        await store.setHistoryLimit(historyLimit);
      }
      return null;
    });
  }

  /// Like [_run], but only while local history may be touched.
  Future<bool> _runLocal(FutureOr<Object?> Function() action) async {
    final authorizedRevision = stateMachine.state.revision;
    if (!stateMachine.state.permitsLocalWork) {
      store.setStatusMessage('Local history is locked in this app state');
      return false;
    }
    return _run(() {
      if (stateMachine.state.revision != authorizedRevision ||
          !stateMachine.state.permitsLocalWork) {
        throw StateError('stale local operation authorization');
      }
      return action();
    });
  }

  /// Runs [action]; on failure shows a user-safe message. Returns whether the
  /// action completed.
  Future<bool> _run(FutureOr<Object?> Function() action) async {
    try {
      await action();
      return true;
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            key: const Key('operation-failed-snackbar'),
            content: Text(userFacingFailure(error)),
          ),
        );
      }
      return false;
    }
  }
}

class _ClipCard extends StatelessWidget {
  const _ClipCard({
    super.key,
    required this.clip,
    required this.now,
    required this.selected,
    required this.onSelect,
    this.quickCopyLabel,
    required this.queued,
    required this.onCopy,
    required this.onToggleQueued,
    required this.onTogglePinned,
    required this.onAction,
  });

  final ClipItem clip;
  final DateTime now;
  final bool selected;
  final VoidCallback onSelect;
  final String? quickCopyLabel;
  final bool queued;
  final VoidCallback onCopy;
  final VoidCallback onToggleQueued;
  final VoidCallback onTogglePinned;
  final ValueChanged<_ClipAction> onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: selected
            ? BorderSide(color: colors.primary, width: 1.5)
            : BorderSide.none,
      ),
      color: selected ? const Color(0xff12223a) : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onSelect,
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
                  ClipContentPreview(
                    key: Key('clip-preview-${clip.id}'),
                    text: clip.summary,
                    style: clip.kind == ClipKind.code
                        ? const TextStyle(fontFamily: 'monospace')
                        : null,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: <Widget>[
                      _MetaChip(
                        label: clip.kind.label,
                        tooltip: 'Detected content type. Filter by type above.',
                      ),
                      if (clip.collection case final collection?)
                        _MetaChip(
                          label: collection,
                          tooltip:
                              'Collection. Change it with ⋯ → Move to collection.',
                        ),
                      if (clip.sourceApplication case final source?)
                        _MetaChip(
                          label: source,
                          tooltip: 'Application this was copied from',
                        ),
                      ...clip.tags.map(
                        (tag) => _MetaChip(
                          label: '#$tag',
                          tooltip:
                              'Tag. Search for it, or change tags with ⋯ → Edit tags.',
                        ),
                      ),
                      _MetaChip(
                        label: relativeTimeLabel(clip.sortTimestamp, now),
                        tooltip:
                            'Last copied ${_formatTimestamp(clip.sortTimestamp)}\n'
                            'First saved ${_formatTimestamp(clip.createdAt)}',
                      ),
                      _MetaChip(
                        label: clipSizeLabel(
                          text: clip.text,
                          byteLength: clip.byteLength,
                        ),
                        tooltip: 'Size of this clip',
                      ),
                      if (quickCopyLabel case final shortcut?)
                        _MetaChip(
                          label: shortcut,
                          tooltip:
                              'Press $shortcut to copy this clip and hide ClipTown',
                        ),
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
                  icon: Icon(
                    queued ? Icons.playlist_remove : Icons.playlist_add,
                  ),
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
                    if (clip.text != null && clip.kind != ClipKind.files)
                      const PopupMenuItem(
                        value: _ClipAction.editText,
                        child: Text('Edit text'),
                      ),
                    const PopupMenuItem(
                      value: _ClipAction.tags,
                      child: Text('Edit tags'),
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
      ),
    );
  }
}

class _ClipPreview extends StatelessWidget {
  const _ClipPreview({required this.clip});

  final ClipItem clip;

  @override
  Widget build(BuildContext context) {
    if (clip.kind == ClipKind.color) {
      if (parseHexColor(clip.text) case final swatch?) {
        return Tooltip(
          message: 'Colour ${clip.text?.trim()}',
          child: Container(
            key: Key('color-swatch-${clip.id}'),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: swatch,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white24, width: 2),
            ),
          ),
        );
      }
    }
    if (clip.kind == ClipKind.image && clip.dataBase64 != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          base64Decode(clip.dataBase64!),
          width: 56,
          height: 56,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) =>
              const _KindAvatar(label: 'I', tooltip: 'Image'),
        ),
      );
    }
    return _KindAvatar(
      label: clip.kind.label.characters.first,
      tooltip: clip.kind.label,
    );
  }
}

class _KindAvatar extends StatelessWidget {
  const _KindAvatar({required this.label, required this.tooltip});

  final String label;
  final String tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: CircleAvatar(child: Text(label)),
  );
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label, this.tooltip});

  final String label;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final chip = _chip(context);
    final message = tooltip;
    return message == null ? chip : Tooltip(message: message, child: chip);
  }

  Widget _chip(BuildContext context) => DecoratedBox(
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
  Widget build(BuildContext context) => Tooltip(
    message: isError
        ? 'Something needs attention. Clipboard contents are never shown in '
              'errors.'
        : 'What ClipTown last did with your clipboard. History is encrypted '
              'on this device.',
    child: DecoratedBox(
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
              : 'Copy something and it appears here, or add a local clip.',
        ),
      ],
    ),
  );
}

enum _ClipAction {
  rename,
  editText,
  tags,
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

String _formatTimestamp(DateTime timestamp) {
  final local = timestamp.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

@immutable
class _KeyBinding {
  const _KeyBinding(this.activator, this.onKey, {this.when});

  final ShortcutActivator activator;
  final VoidCallback onKey;

  /// Extra condition; when false the key is left for the focused widget.
  final bool Function()? when;
}

/// The message shown for a failed operation. Only messages known to be fixed
/// strings are surfaced; anything else (e.g. a JSON decode error that quotes
/// its input) could contain clipboard content and is replaced.
@visibleForTesting
String userFacingFailure(Object error) => switch (error) {
  ClipInputException(:final message) => message,
  PlatformException(code: 'requires_approval') =>
    'Approve ClipTown in System Settings → General → Login Items to finish '
        'turning on Open at login.',
  PlatformException(code: 'unsupported') =>
    'Open at login needs macOS 13 or later.',
  _ => 'The operation failed without exposing clipboard data.',
};

/// App bar brand mark: the ClipTown icon beside the name.
class _AppTitle extends StatelessWidget {
  const _AppTitle();

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Tooltip(
        message: 'ClipTown — encrypted, searchable clipboard history',
        child: ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: Image.asset(
            'assets/icon/app_icon_256.png',
            key: const Key('app-logo'),
            width: 30,
            height: 30,
            filterQuality: FilterQuality.medium,
            semanticLabel: 'ClipTown logo',
          ),
        ),
      ),
      const SizedBox(width: 10),
      const Text('ClipTown'),
    ],
  );
}
