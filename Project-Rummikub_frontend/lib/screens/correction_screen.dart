import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../logic/set_validator.dart';
import '../models/models.dart';
import '../providers/game_provider.dart';
import '../services/api_service.dart';
import '../services/file_download.dart';
import '../services/firebase_service.dart';
import '../services/roboflow_debug_dump.dart';
import '../services/vision_parser.dart';
import '../widgets/rummikub_tiles.dart';
import 'result_screen.dart';

/// Human-in-the-loop editor: tap a tile, then tap a + slot to move it.
///
/// Tap the same tile again to edit or delete. Invalid sets get a red border.
class CorrectionScreen extends StatefulWidget {
  const CorrectionScreen({super.key, this.arenaChallenge});

  final ArenaChallenge? arenaChallenge;

  bool get isArena => arenaChallenge != null;

  @override
  State<CorrectionScreen> createState() => _CorrectionScreenState();
}

class _CorrectionScreenState extends State<CorrectionScreen> {
  bool _isBusy = false;
  String? _selectedTileId;
  String? _selectedSetId;

  bool get _hasSelection => _selectedTileId != null;

  void _clearSelection() {
    setState(() {
      _selectedTileId = null;
      _selectedSetId = null;
    });
  }

  Future<void> _onSolvePressed(GameState currentState) async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    try {
      final result = await ApiService().solveBoard(currentState);
      if (!mounted) return;
      final vision = context.read<GameProvider>().visionOutput;
      if (vision != null) {
        try {
          await FirebaseService().saveVisionCorrection(
            visionOutput: vision,
            userCorrectedOutput: currentState,
          );
        } catch (_) {
          // Training log must not block the solve result.
        }
        if (!mounted) return;
        context.read<GameProvider>().clearVisionOutput();
      }
      context.read<GameProvider>().updateGameState(result.optimalState);
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ResultScreen(
            beforeState: result.originalState,
            afterState: result.optimalState,
            tilesDropped: result.tilesUsedFromRack,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_messageFromError(error)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _onArenaSubmit(GameState currentState) async {
    if (_isBusy) return;
    final challenge = widget.arenaChallenge!;
    final (ok, message) = SetValidator.validateBoard(currentState.board);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      return;
    }

    final initialRackIds =
        challenge.initialState.rack.map((tile) => tile.id).toSet();
    final boardIds = currentState.board
        .expand((set) => set.tiles)
        .map((tile) => tile.id)
        .toSet();
    final score = initialRackIds.where(boardIds.contains).length;

    setState(() => _isBusy = true);
    try {
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ResultScreen(
            beforeState: challenge.initialState,
            afterState: currentState,
            tilesDropped: score,
            algorithmScore: challenge.algorithmScore,
            challengeId: challenge.id,
            algorithmAfterState: challenge.algorithmAfterState,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  String _messageFromError(Object error) {
    final text = error.toString();
    const prefix = 'Exception: ';
    return text.startsWith(prefix) ? text.substring(prefix.length) : text;
  }

  void _onTileTap(Tile tile, {String? setId}) {
    if (_selectedTileId == tile.id && _selectedSetId == setId) {
      _openEditDialog(tile, setId: setId);
      return;
    }
    setState(() {
      _selectedTileId = tile.id;
      _selectedSetId = setId;
    });
  }

  void _onDrop(TileDestination destination) {
    if (_selectedTileId == null) return;
    context.read<GameProvider>().moveTile(
          tileId: _selectedTileId!,
          fromSetId: _selectedSetId,
          destination: destination,
        );
    _clearSelection();
  }

  Future<void> _openEditDialog(Tile tile, {String? setId}) async {
    final result = await showDialog<TileEditResult>(
      context: context,
      builder: (context) => TileEditDialog(tile: tile),
    );
    if (!mounted || result == null) return;
    final provider = context.read<GameProvider>();
    if (result.delete) {
      provider.deleteTile(tile, setId: setId);
    } else {
      provider.replaceTile(
        tile,
        tile.copyWith(color: result.color, value: result.value),
        setId: setId,
      );
    }
    _clearSelection();
  }

  Future<void> _exportRoboflowDump(RoboflowDebugDump dump) async {
    downloadBytes(dump.tableJpeg, 'rummikub-table-sent.jpg', 'image/jpeg');
    await Future<void>.delayed(const Duration(milliseconds: 350));
    downloadBytes(dump.rackJpeg, 'rummikub-rack-sent.jpg', 'image/jpeg');
    await Future<void>.delayed(const Duration(milliseconds: 350));
    downloadBytes(
      Uint8List.fromList(utf8.encode(dump.tableJson)),
      'rummikub-table-workflow.json',
      'application/json',
    );
    await Future<void>.delayed(const Duration(milliseconds: 350));
    downloadBytes(
      Uint8List.fromList(utf8.encode(dump.rackJson)),
      'rummikub-rack-workflow.json',
      'application/json',
    );
    await Clipboard.setData(
      ClipboardData(
        text:
            '${dump.unfilteredSummary}\n\n=== TABLE WORKFLOW JSON ===\n${dump.tableJson}\n\n=== RACK WORKFLOW JSON ===\n${dump.rackJson}',
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Downloaded the exact JPEGs + JSON. JSON also copied. Send those files to the Roboflow agent.',
        ),
      ),
    );
  }

  Future<void> _addTile() async {
    final result = await showDialog<TileEditResult>(
      context: context,
      builder: (context) => const TileEditDialog(allowDelete: false),
    );
    if (!mounted || result == null || result.delete) return;
    context.read<GameProvider>().addTileToRack(
          Tile(color: result.color, value: result.value),
        );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<GameProvider>(
      builder: (context, gameProvider, _) {
        final gameState = gameProvider.gameState;
        final groupingOff = VisionParser.disableSpatialGrouping &&
            gameProvider.visionOutput != null;
        final dump = gameProvider.lastRoboflowDump;
        final (boardValid, boardError) =
            SetValidator.validateBoard(gameState.board);
        final hasTiles = !gameState.isBoardEmpty || !gameState.isRackEmpty;
        final canSubmit = !groupingOff && boardValid && hasTiles && !_isBusy;
        final hint = groupingOff
            ? (_hasSelection
                ? 'Tap a selected tile again to edit or delete it. Grouping is off — these are raw detections.'
                : 'Raw detections with no series grouping. Tap a tile to select it, then tap it again to edit.')
            : (_hasSelection
                ? 'Tap + to the left or right of any tile to place it, or tap it again to edit.'
                : 'Tap a tile to select it, then tap + on either side of a tile to place it.');

        return Stack(
          children: [
            Scaffold(
              appBar: AppBar(
                title: Text(widget.isArena ? 'Challenge' : 'Correct Tiles'),
                actions: [
                  IconButton(
                    tooltip: 'Add tile',
                    onPressed: _addTile,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              body: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
                children: [
                  Text(
                    hint,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (gameProvider.lastVisionDebug != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      gameProvider.lastVisionDebug!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  if (gameProvider.lastRoboflowDump != null) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => _exportRoboflowDump(
                        gameProvider.lastRoboflowDump!,
                      ),
                      icon: const Icon(Icons.download),
                      label: const Text('Download JPEG + JSON for Roboflow'),
                    ),
                  ],
                  if (!groupingOff && !boardValid && hasTiles) ...[
                    const SizedBox(height: 8),
                    Text(
                      boardError,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (groupingOff) ...[
                    SectionHeader(
                      title: 'Rack',
                      subtitle: '${gameState.rackSize} raw tiles',
                    ),
                    const SizedBox(height: 8),
                    if (dump != null && dump.rackDetections.isNotEmpty)
                      _RawDetectionMap(
                        jpeg: dump.rackJpeg,
                        detections: dump.rackDetections,
                        onTapIndex: (index) {
                          if (index < gameState.rack.length) {
                            _onTileTap(gameState.rack[index]);
                          }
                        },
                      ),
                    const SizedBox(height: 8),
                    _ungroupedTileWrap(
                      tiles: [
                        for (final tile in gameState.rack) (tile, null),
                      ],
                      extra: EmptySlot(
                        label: _hasSelection ? 'Rack' : '+',
                        onTap: _hasSelection
                            ? () => _onDrop(TileDestination.rack)
                            : _addTile,
                      ),
                    ),
                    const SizedBox(height: 24),
                    SectionHeader(
                      title: 'Table',
                      subtitle:
                          '${gameState.totalTilesOnBoard} raw tiles (not grouped)',
                    ),
                    const SizedBox(height: 8),
                    if (dump != null && dump.tableDetections.isNotEmpty)
                      _RawDetectionMap(
                        jpeg: dump.tableJpeg,
                        detections: dump.tableDetections,
                        onTapIndex: (index) {
                          if (index < gameState.board.length &&
                              gameState.board[index].tiles.isNotEmpty) {
                            final set = gameState.board[index];
                            _onTileTap(set.tiles.first, setId: set.id);
                          }
                        },
                      ),
                    const SizedBox(height: 8),
                    if (gameState.isBoardEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('No table detections.'),
                      )
                    else
                      _ungroupedTileWrap(
                        tiles: [
                          for (final set in gameState.board)
                            for (final tile in set.tiles) (tile, set.id),
                        ],
                      ),
                  ] else ...[
                    SectionHeader(
                      title: 'Board',
                      subtitle: '${gameState.numberOfSets} sets',
                    ),
                    const SizedBox(height: 8),
                    if (gameState.isBoardEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'No sets on the board. Add a new set below.',
                        ),
                      )
                    else
                      ...gameState.board.asMap().entries.map((entry) {
                        final set = entry.value;
                        return BoardSetCard(
                          setIndex: entry.key,
                          tileSet: set,
                          selectedTileId: _selectedTileId,
                          onTileTap: (tile) => _onTileTap(tile, setId: set.id),
                          onInsertAt: _hasSelection
                              ? (index) => _onDrop(
                                    TileDestination.insertIntoSet(
                                      set.id,
                                      index,
                                    ),
                                  )
                              : null,
                        );
                      }),
                    const SizedBox(height: 8),
                    _DropZone(
                      label: 'New set',
                      enabled: _hasSelection,
                      onTap: () => _onDrop(TileDestination.newSet),
                    ),
                    const SizedBox(height: 24),
                    SectionHeader(
                      title: 'Rack',
                      subtitle: '${gameState.rackSize} tiles',
                    ),
                    const SizedBox(height: 8),
                    _ungroupedTileWrap(
                      tiles: [
                        for (final tile in gameState.rack) (tile, null),
                      ],
                      extra: EmptySlot(
                        label: _hasSelection ? 'Rack' : '+',
                        onTap: _hasSelection
                            ? () => _onDrop(TileDestination.rack)
                            : _addTile,
                      ),
                    ),
                  ],
                ],
              ),
              floatingActionButton: groupingOff && !widget.isArena
                  ? null
                  : FloatingActionButton.extended(
                      onPressed: canSubmit
                          ? () => widget.isArena
                              ? _onArenaSubmit(gameState)
                              : _onSolvePressed(gameState)
                          : null,
                      icon: Icon(
                        widget.isArena ? Icons.check : Icons.play_arrow,
                      ),
                      label: Text(widget.isArena ? 'Submit' : 'Solve'),
                    ),
            ),
            if (_isBusy)
              const Positioned.fill(
                child: AbsorbPointer(
                  child: ColoredBox(
                    color: Color(0x80000000),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _ungroupedTileWrap({
    required List<(Tile tile, String? setId)> tiles,
    Widget? extra,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final entry in tiles)
          TileView(
            tile: entry.$1,
            selected: entry.$1.id == _selectedTileId &&
                _selectedSetId == entry.$2,
            onTap: () => _onTileTap(entry.$1, setId: entry.$2),
          ),
        if (extra != null) extra,
      ],
    );
  }
}

class _RawDetectionMap extends StatefulWidget {
  const _RawDetectionMap({
    required this.jpeg,
    required this.detections,
    this.onTapIndex,
  });

  final Uint8List jpeg;
  final List<TileDetection> detections;
  final ValueChanged<int>? onTapIndex;

  @override
  State<_RawDetectionMap> createState() => _RawDetectionMapState();
}

class _RawDetectionMapState extends State<_RawDetectionMap> {
  ui.Image? _image;
  var _ready = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(_RawDetectionMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.jpeg, widget.jpeg)) {
      _ready = false;
      _decode();
    }
  }

  Future<void> _decode() async {
    try {
      final image = await decodeImageFromList(widget.jpeg);
      if (!mounted) return;
      setState(() {
        _image = image;
        _ready = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _image = null;
        _ready = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final image = _image;
    if (image == null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.memory(
          widget.jpeg,
          height: 220,
          width: double.infinity,
          fit: BoxFit.contain,
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const maxHeight = 360.0;
        final scale = math.min(
          constraints.maxWidth / image.width,
          maxHeight / image.height,
        );
        final width = image.width * scale;
        final height = image.height * scale;
        return Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: width,
              height: height,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Image.memory(widget.jpeg, fit: BoxFit.fill),
                  ),
                  for (var i = 0; i < widget.detections.length; i++)
                    _positionedDetection(widget.detections[i], scale, i),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _positionedDetection(
    TileDetection detection,
    double scale,
    int index,
  ) {
    final boxWidth = math.max(28.0, detection.width * scale);
    final boxHeight = math.max(36.0, detection.height * scale);
    final left = (detection.x - detection.width / 2) * scale;
    final top = (detection.y - detection.height / 2) * scale;
    final foreground =
        detection.color == 'YELLOW' ? Colors.black87 : Colors.white;
    return Positioned(
      left: left,
      top: top,
      width: boxWidth,
      height: boxHeight,
      child: Material(
        color: colorForTile(detection.color).withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          onTap: widget.onTapIndex == null
              ? null
              : () => widget.onTapIndex!(index),
          borderRadius: BorderRadius.circular(4),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 1.5),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  detection.shortLabel,
                  style: TextStyle(
                    color: foreground,
                    fontWeight: FontWeight.bold,
                    fontSize: boxHeight < 28 ? 10 : 16,
                  ),
                ),
                if (boxHeight >= 44)
                  Text(
                    detection.confidence.toStringAsFixed(2),
                    style: TextStyle(
                      color: foreground,
                      fontSize: 9,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DropZone extends StatelessWidget {
  const _DropZone({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: enabled
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: Text(
              label,
              style: theme.textTheme.labelLarge,
            ),
          ),
        ),
      ),
    );
  }
}
