import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../config/roboflow_config.dart';
import '../debug_log.dart';
import '../providers/game_provider.dart';
import '../services/vision_image.dart';
import '../services/vision_service.dart';
import 'arena_list_screen.dart';
import 'correction_screen.dart';

/// Capture screen: table photo, then rack photo, then correction.
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final ImagePicker _picker = ImagePicker();
  final VisionService _visionService = VisionService();

  XFile? _tableImage;
  XFile? _rackImage;
  Uint8List? _tablePreview;
  Uint8List? _rackPreview;
  String? _tableDebug;
  String? _rackDebug;
  String? _visionDebug;
  bool _isProcessing = false;

  bool get _hasTable => _tableImage != null;
  bool get _hasRack => _rackImage != null;

  @override
  void initState() {
    super.initState();
    // #region agent log
    debugLog(
      location: 'capture_screen.dart:initState',
      message: 'two-photo CaptureScreen mounted',
      hypothesisId: 'H1',
      data: {
        'hasApiKey': RoboflowConfig.hasApiKey,
        'runUrl': RoboflowConfig.runUrl,
      },
    );
    // #endregion
  }

  Future<void> _pick(ImageSource source, {required bool table}) async {
    if (_isProcessing) return;
    // #region agent log
    debugLog(
      location: 'capture_screen.dart:_pick',
      message: 'pick started',
      hypothesisId: 'H2',
      data: {
        'table': table,
        'source': source.name,
        'hasTable': _hasTable,
        'hasRack': _hasRack,
      },
    );
    // #endregion
    try {
      // Flutter web's image_picker resizes via a canvas using element.width
      // (not naturalWidth). When that is 0, toBlob writes a ~651-byte empty
      // JPEG and Roboflow returns no tiles. Skip picker resize on web.
      final image = await _picker.pickImage(
        source: source,
        maxWidth: kIsWeb ? null : 1920,
        maxHeight: kIsWeb ? null : 1920,
        imageQuality: kIsWeb ? null : 85,
        preferredCameraDevice: CameraDevice.rear,
      );
      if (image == null) return;
      final bytes = await image.readAsBytes();
      if (!mounted) return;
      // #region agent log
      debugLog(
        location: 'capture_screen.dart:_pick',
        message: 'pick succeeded',
        hypothesisId: 'H4',
        data: {
          'table': table,
          'bytes': bytes.length,
          'mimeType': image.mimeType,
          'name': image.name,
          'isJpeg': bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8,
          'skippedWebPickerResize': kIsWeb,
          'hasTable': _hasTable,
          'hasRack': _hasRack,
        },
      );
      // #endregion
      if (bytes.length < 8000) {
        // #region agent log
        debugLog(
          location: 'capture_screen.dart:_pick',
          message: 'rejected tiny photo',
          hypothesisId: 'H4',
          data: {'table': table, 'bytes': bytes.length},
        );
        // #endregion
        _showError(
          'That photo was empty or too small to recognize. Try again, or pick from the gallery.',
        );
        return;
      }
      final prepared = prepareVisionJpeg(bytes);
      setState(() {
        if (table) {
          _tableImage = image;
          _tablePreview = prepared.bytes;
          _tableDebug = prepared.debugLine;
        } else {
          _rackImage = image;
          _rackPreview = prepared.bytes;
          _rackDebug = prepared.debugLine;
        }
      });
    } catch (error) {
      // #region agent log
      debugLog(
        location: 'capture_screen.dart:_pick',
        message: 'pick failed',
        hypothesisId: 'H3',
        data: {'table': table, 'error': error.toString()},
      );
      // #endregion
      if (!mounted) return;
      _showError('Could not open the ${table ? 'table' : 'rack'} photo: $error');
    }
  }

  Future<void> _recognize() async {
    final tableBytes = _tablePreview;
    final rackBytes = _rackPreview;
    if (tableBytes == null || rackBytes == null || _isProcessing) return;

    setState(() => _isProcessing = true);
    // #region agent log
    debugLog(
      location: 'capture_screen.dart:_recognize',
      message: 'recognize started',
      hypothesisId: 'H1',
      data: {
        'tableBytes': tableBytes.length,
        'rackBytes': rackBytes.length,
        'tableDebug': _tableDebug,
        'rackDebug': _rackDebug,
      },
    );
    // #endregion
    try {
      final gameState = await _visionService.processBoardAndRackFromBytes(
        boardImage: tableBytes,
        rackImage: rackBytes,
      );
      if (!mounted) return;
      final dump = _visionService.lastDump;
      final summary =
          '${_tableDebug ?? ''} | ${_rackDebug ?? ''} || '
          '${dump?.unfilteredSummary ?? _visionService.lastSummaries.join(' | ')}';
      context.read<GameProvider>().updateGameState(
            gameState,
            fromVision: true,
            visionDebug: summary,
            roboflowDump: dump,
          );
      setState(() => _visionDebug = summary);
      if (gameState.board.isEmpty && gameState.rack.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No tiles detected. $summary'),
          ),
        );
      }
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const CorrectionScreen()),
      );
      if (!mounted) return;
      _resetPhotos();
    } catch (error) {
      // #region agent log
      debugLog(
        location: 'capture_screen.dart:_recognize',
        message: 'recognize failed',
        hypothesisId: 'H4',
        data: {'error': error.toString()},
      );
      // #endregion
      if (!mounted) return;
      _showError(_messageFromError(error));
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _resetPhotos() {
    setState(() {
      _tableImage = null;
      _rackImage = null;
      _tablePreview = null;
      _rackPreview = null;
      _tableDebug = null;
      _rackDebug = null;
      _visionDebug = null;
    });
  }

  void _clearPhoto({required bool table}) {
    setState(() {
      if (table) {
        _tableImage = null;
        _tablePreview = null;
        _tableDebug = null;
      } else {
        _rackImage = null;
        _rackPreview = null;
        _rackDebug = null;
      }
    });
  }

  void _enterManually() {
    context.read<GameProvider>().beginManualEntry();
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CorrectionScreen()),
    );
  }

  void _openArena() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ArenaListScreen()),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }

  String _messageFromError(Object error) {
    if (error is VisionException) return error.message;
    final text = error.toString();
    const prefix = 'Exception: ';
    return text.startsWith(prefix) ? text.substring(prefix.length) : text;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Play'),
      ),
      body: Stack(
        children: [
          ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Text(
                  'Photograph the table first, then your rack. Two shots keep the tiles large enough to read.',
                  style: TextStyle(fontSize: 18),
                  textAlign: TextAlign.center,
                ),
                if (!RoboflowConfig.hasApiKey) ...[
                  const SizedBox(height: 16),
                  Material(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'Roboflow API key is not set. Run with --dart-define=ROBOFLOW_API_KEY=your_key',
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                _PhotoStep(
                  step: 1,
                  title: 'Table',
                  subtitle: 'The sets already on the board',
                  preview: _tablePreview,
                  debugLine: _tableDebug,
                  onCamera: () => _pick(ImageSource.camera, table: true),
                  onGallery: () => _pick(ImageSource.gallery, table: true),
                  onClear: _hasTable ? () => _clearPhoto(table: true) : null,
                ),
                const SizedBox(height: 20),
                _PhotoStep(
                  step: 2,
                  title: 'Rack',
                  subtitle: _hasTable
                      ? 'Your tiles'
                      : 'Photograph the table first',
                  preview: _rackPreview,
                  debugLine: _rackDebug,
                  enabled: _hasTable,
                  onCamera: () => _pick(ImageSource.camera, table: false),
                  onGallery: () => _pick(ImageSource.gallery, table: false),
                  onClear: _hasRack ? () => _clearPhoto(table: false) : null,
                ),
                if (_visionDebug != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _visionDebug!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (_hasTable && _hasRack) ...[
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _isProcessing ? null : _recognize,
                    icon: const Icon(Icons.search),
                    label: const Text('Recognize tiles'),
                  ),
                ],
                const SizedBox(height: 28),
                OutlinedButton.icon(
                  onPressed: _enterManually,
                  icon: const Icon(Icons.grid_on),
                  label: const Text('Enter tiles manually'),
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: _openArena,
                  icon: const Icon(Icons.emoji_events_outlined),
                  label: const Text('Community challenge'),
                ),
              ],
            ),
          if (_isProcessing)
            const Positioned.fill(
              child: AbsorbPointer(
                child: ColoredBox(
                  color: Color(0x80000000),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Recognizing tiles...'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PhotoStep extends StatelessWidget {
  const _PhotoStep({
    required this.step,
    required this.title,
    required this.subtitle,
    required this.preview,
    required this.onCamera,
    required this.onGallery,
    this.debugLine,
    this.onClear,
    this.enabled = true,
  });

  final int step;
  final String title;
  final String subtitle;
  final Uint8List? preview;
  final String? debugLine;
  final VoidCallback onCamera;
  final VoidCallback onGallery;
  final VoidCallback? onClear;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Step $step of 2 — $title',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(subtitle, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 12),
          if (preview != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                preview!,
                height: 140,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            )
          else
            Container(
              height: 88,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Text(
                enabled ? 'No photo yet' : 'Waiting for table photo',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          const SizedBox(height: 12),
          if (debugLine != null)
            Text(debugLine!, style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: enabled ? onCamera : null,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Camera'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: enabled ? onGallery : null,
                  icon: const Icon(Icons.photo_library),
                  label: const Text('Gallery'),
                ),
              ),
            ],
          ),
          if (onClear != null)
            TextButton(
              onPressed: onClear,
              child: const Text('Retake'),
            ),
        ],
      ),
    );
  }
}
