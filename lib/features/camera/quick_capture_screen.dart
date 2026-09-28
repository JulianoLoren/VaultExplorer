import 'dart:async';
import 'dart:math' as math;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:vaultexplorer/core/api/vault_engine_events.dart';
import 'package:vaultexplorer/core/api/vault_file_io_api.dart';
import 'package:vaultexplorer/core/api/vault_lifecycle_api.dart';
import 'package:vaultexplorer/core/api/quick_capture_api.dart';
import 'package:vaultexplorer/core/extensions/l10n_extension.dart';
import 'package:vaultexplorer/core/providers/vault_engine_providers.dart';
import 'package:vaultexplorer/data/services/app_settings_service.dart';
import 'package:vaultexplorer/features/share_import/share_destination_sheet.dart';
import 'package:vaultexplorer/features/tools/models/tool_models.dart';
import 'camera_vault_service.dart';
import 'camera_capture_controls_controller.dart';
import 'camera_capture_session_controller.dart';
import 'camera_ui_components.dart';
import 'camera_media_review_view.dart';
import 'vault_camera_controller.dart';
import '../image_editor/image_editor_screen.dart';

const _quickCaptureControlsKey = 'camera_capture';
const _quickCaptureSessionKey = 'quick_capture';

class QuickCaptureScreen extends ConsumerStatefulWidget {
  const QuickCaptureScreen({super.key});

  @override
  ConsumerState<QuickCaptureScreen> createState() =>
      _QuickCaptureScreenState();
}

enum _Phase { camera, reviewing, saving }

class _QuickCaptureScreenState extends ConsumerState<QuickCaptureScreen>
    with WidgetsBindingObserver {
  late final VaultFileIoApi _fileIoApi;
  late final VaultLifecycleApi _lifecycleApi;
  late final VaultEngineEvents _engineEvents;
  late final QuickCaptureApi _quickCaptureApi;
  late final VaultCameraController _cameraController;

  AppLifecycleState _lastLifecycleState = AppLifecycleState.resumed;
  Future<void>? _backgroundingFuture;
  bool _isOpeningCamera = false;

  _Phase _phase = _Phase.camera;
  ScratchpadSession? _pendingScratchpad;
  final List<CapturedMediaItem> _capturedMedia = [];
  final ScrollController _trayScrollController = ScrollController();
  int _pendingPhotoCount = 0;
  bool _isTakingPhoto = false;
  String? _saveError;

  bool _isRecording = false;
  bool _pendingStopAfterStart = false;
  bool _showShutterFlash = false;
  double _baseZoom = 1.0;
  Timer? _exposureHideTimer;
  Offset? _focusPoint;

  DateTime? _recordingStart;
  Timer? _timer;

  StreamSubscription<({double x, double y, double z})>? _sensorSubscription;
  StreamSubscription<Map<String, dynamic>>? _cameraEventSubscription;
  double _deviceTurns = 0.0;
  int _displayRotation = 0;

  double get _iconTurns => cameraIconTurns(
    deviceTurns: _deviceTurns,
    displayRotation: _displayRotation,
  );

  CameraCaptureControlsState get _captureControls =>
      ref.read(cameraCaptureControlsProvider(_quickCaptureControlsKey));

  CameraCaptureControls get _captureControlsController =>
      ref.read(cameraCaptureControlsProvider(_quickCaptureControlsKey).notifier);

  CameraCaptureSessionState get _captureSession =>
      ref.read(cameraCaptureSessionProvider(_quickCaptureSessionKey));

  CameraCaptureSession get _captureSessionController =>
      ref.read(cameraCaptureSessionProvider(_quickCaptureSessionKey).notifier);

  bool get _isInitialized => _captureSession.isInitialized;
  String get _selectedCameraId => _captureSession.selectedCameraId;
  List<NativeCameraLens> get _lenses => _captureSession.lenses;
  bool get _isEncrypting => _captureSession.isEncrypting;
  bool get _isStartingVideo => _captureSession.isStartingVideo;
  String? get _permissionError => _captureSession.permissionError;
  bool get _isCountingDown => _captureSession.countdownValue > 0 && _captureSession.isCountingDown;
  int get _countdownValue => _captureSession.countdownValue;
  String get _busyLabel => _captureSession.busyLabel;
  String get _timerText => _captureSession.timerText;
  double get _currentZoom => _captureSession.currentZoom;
  double get _minZoom => _captureSession.minZoom;
  double get _maxZoom => _captureSession.maxZoom;
  double get _currentExposureEv => _captureSession.currentExposureEv;
  double get _minExposureEv => _captureSession.minExposureEv;
  double get _maxExposureEv => _captureSession.maxExposureEv;
  bool get _showExposureSlider => _captureSession.showExposureSlider;

  @override
  void initState() {
    super.initState();
    _fileIoApi = ref.read(vaultFileIoApiProvider);
    _lifecycleApi = ref.read(vaultLifecycleApiProvider);
    _engineEvents = ref.read(vaultEngineEventsProvider);
    _quickCaptureApi = ref.read(quickCaptureApiProvider);
    _cameraController = VaultCameraController(_engineEvents);

    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    WidgetsBinding.instance.addObserver(this);
    _cameraEventSubscription = _cameraController.events.listen(
      _handleCameraEvent,
    );
    _initCamera();
    _startSensorListener();
    unawaited(_refreshDisplayRotation());
  }

  void _handleCameraEvent(Map<String, dynamic> event) {
    if (event['event'] != 'error' || !mounted) return;
    _captureSessionController.setPermissionError(
      context.l10n.cameraDisconnectedError(
        event['message'] ?? context.l10n.unknownErrorFallback,
      ),
    );
  }

  void _startSensorListener() {
    _sensorSubscription = VaultCameraController.accelerometerEventStream()
        .listen((event) {
          double magnitude = math.sqrt(event.x * event.x + event.y * event.y);
          if (magnitude < 2.0) return;

          double angle = math.atan2(event.x, event.y);
          double turns = angle / (2 * math.pi);
          double snappedTurns = (turns * 4).round() / 4.0;
          if (snappedTurns == -0.5) snappedTurns = 0.5;

          if (_deviceTurns != snappedTurns && mounted) {
            setState(() => _deviceTurns = snappedTurns);
            unawaited(applyOrientationSilent(_cameraController, _computeDeviceRotationDegrees()));
          }
        });
  }

  int _computeDeviceRotationDegrees() {
    return ((_deviceTurns * 360).round() % 360 + 360) % 360;
  }

  @override
  void didChangeMetrics() {
    unawaited(_refreshDisplayRotation());
  }

  Future<void> _refreshDisplayRotation() async {
    final rotation = await VaultCameraController.getDisplayRotation();
    if (!mounted || rotation == _displayRotation) return;
    setState(() => _displayRotation = rotation);
  }

  void _scrollToEndOfTray() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_trayScrollController.hasClients) {
        _trayScrollController.animateTo(
          _trayScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  bool get _isOwnRouteCurrent => ModalRoute.of(context)?.isCurrent ?? false;

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (!_isOwnRouteCurrent) return false;
    if (_phase == _Phase.reviewing && _capturedMedia.isNotEmpty) {
      return true;
    }
    if (_isRecording ||
        _isEncrypting ||
        _isCountingDown ||
        _phase == _Phase.saving ||
        _pendingPhotoCount > 0) {
      return true;
    }
    if (_capturedMedia.isNotEmpty) {
      return true;
    }
    return false;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {}

  @override
  void handleCancelBackGesture() {}

  @override
  void handleCommitBackGesture() {
    if (!_isOwnRouteCurrent) return;
    if (_phase == _Phase.reviewing && _capturedMedia.isNotEmpty) {
      setState(() => _phase = _Phase.camera);
    } else if (_capturedMedia.isNotEmpty) {
      HapticFeedback.lightImpact();
      _discardAllMedia();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _trayScrollController.dispose();
    _timer?.cancel();
    _exposureHideTimer?.cancel();
    _sensorSubscription?.cancel();
    _cameraEventSubscription?.cancel();
    unawaited(_cameraController.dispose());

    if (_isRecording) {
      unawaited(_fileIoApi.setKeepScreenOn(false));
    }

    final pending = _pendingScratchpad;
    if (pending != null) {
      unawaited(_quickCaptureApi.discardSession(pending.sessionToken));
    }

    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    super.dispose();
  }

 @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lastLifecycleState = state;
    if (_phase != _Phase.camera) return;

    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _backgroundingFuture = _handleGoingBackground();
    } else if (state == AppLifecycleState.resumed && _backgroundingFuture != null) {
      unawaited(_handleResumed());
    }
  }

  Future<void> _handleGoingBackground() async {
    if (_isRecording) {
      await _stopVideoRecording();
    }
    await _cameraController.close();
    if (mounted && _phase == _Phase.camera) {
      _captureSessionController.setUninitialized();
    }
  }

  Future<void> _handleResumed() async {
    final bgFuture = _backgroundingFuture;
    _backgroundingFuture = null;
    unawaited(_refreshDisplayRotation());
    if (bgFuture != null) {
      await bgFuture;
    }
    if (!mounted || _phase != _Phase.camera) return;
    if (!_cameraController.isInitialized) {
      await _initCamera(
        cameraId: _selectedCameraId.isNotEmpty ? _selectedCameraId : null,
      );
    }
  }

  Future<void> _initCamera({String? cameraId}) async {
    if (_isOpeningCamera) return;
    _isOpeningCamera = true;
    try {
      await _captureControlsController.loadPersisted();

      final hasPerms = await VaultCameraController.hasPermissions();
      if (!hasPerms) {
        final granted = await _cameraController.requestPermissions();
        if (!granted) {
          if (mounted) {
            _captureSessionController.setPermissionError(
              context.l10n.cameraPermissionsRequiredMessage,
            );
          }
          return;
        }
      }

      final info = await _cameraController.open(
        cameraId: cameraId,
        facing: _captureControls.preferredFacing,
        quality: _captureControls.videoQuality,
        photoResolution: _captureControls.photoResolution,
      );

      if (!mounted) return;

      if (_phase != _Phase.camera ||
          _lastLifecycleState == AppLifecycleState.paused ||
          _lastLifecycleState == AppLifecycleState.hidden) {
        await _cameraController.close();
        return;
      }

      _captureSessionController.setCameraOpened(info);
      await _cameraController.setFlash(_captureControls.flashMode);
      await _cameraController.setZoom(_currentZoom);
    } catch (e) {
      if (mounted) {
        _captureSessionController.setPermissionError(
          context.l10n.cameraErrorMessage('$e'),
        );
      }
    } finally {
      _isOpeningCamera = false;
    }
  }

  Future<void> _flipCamera() async {
    if (_isRecording ||
        _isEncrypting ||
        _isCountingDown ||
        _isStartingVideo ||
        _lenses.length <= 1) {
      return;
    }
    HapticFeedback.lightImpact();

    final currentLens = _lenses.firstWhere(
      (l) => l.cameraId == _selectedCameraId,
      orElse: () => _lenses.first,
    );
    final targetFacing = currentLens.facing == 'back' ? 'front' : 'back';
    final targetLens = _lenses.firstWhere(
      (l) => l.facing == targetFacing,
      orElse: () => _lenses.firstWhere(
        (l) => l.cameraId != _selectedCameraId,
        orElse: () => currentLens,
      ),
    );

    if (targetLens.cameraId != _selectedCameraId) {
      _captureControlsController.setPreferredFacing(targetFacing);
      _captureSessionController.setUninitialized(cancelCountdown: false);
      await _initCamera(cameraId: targetLens.cameraId);
    }
  }

  Future<void> _changeQuality(String quality) async {
    if (_isRecording ||
        _isEncrypting ||
        _isCountingDown ||
        _isStartingVideo ||
        _captureControls.videoQuality == quality) {
      return;
    }
    _captureControlsController.selectVideoQuality(quality);
    _captureSessionController.setUninitialized(cancelCountdown: false);
    await _initCamera(cameraId: _selectedCameraId);
  }

  Future<void> _changePhotoResolution(String resolution) async {
    if (_isRecording ||
        _isEncrypting ||
        _isCountingDown ||
        _isStartingVideo ||
        _captureControls.photoResolution == resolution) {
      return;
    }
    _captureControlsController.selectPhotoResolution(resolution);
    _captureSessionController.setUninitialized(cancelCountdown: false);
    await _initCamera(cameraId: _selectedCameraId);
  }

  void _onTapToFocus(TapDownDetails details, BoxConstraints constraints) async {
    if (!_cameraController.isInitialized) return;

    final natural = cameraDisplayPointToNatural(
      details.localPosition.dx / constraints.maxWidth,
      details.localPosition.dy / constraints.maxHeight,
      _displayRotation,
    );
    final nx = natural.x;
    final ny = natural.y;

    setState(() => _focusPoint = details.localPosition);
    _captureSessionController.setShowExposureSlider(true);

    await applyFocusAndExposurePoint(_cameraController, nx, ny, logTag: 'QuickCaptureScreen');

    _exposureHideTimer?.cancel();
    _exposureHideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        _captureSessionController.setShowExposureSlider(false);
        setState(() => _focusPoint = null);
        unawaited(_cameraController.resetFocusAndExposure());
      }
    });
  }

  void _onCaptureClicked() {
    if (_isEncrypting) return;
    HapticFeedback.mediumImpact();

    if (_isCountingDown) {
      _captureSessionController.stopCountdown();
      return;
    }

    if (_captureControls.isVideoMode) {
      if (_isRecording) {
        _stopVideoRecording();
      } else if (_isStartingVideo) {
        _pendingStopAfterStart = true;
      } else {
        _startVideoRecording();
      }
    } else {
      _captureControls.timerDelaySeconds > 0
          ? _startPhotoCountdownAndCapture()
          : _takePhoto();
    }
  }

  Future<void> _startPhotoCountdownAndCapture() async {
    final delay = _captureControls.timerDelaySeconds;
    _captureSessionController.startCountdown(delay);

    for (int i = delay; i > 0; i--) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted || !_isCountingDown) return;
      HapticFeedback.lightImpact();
      _captureSessionController.updateCountdown(i - 1);
    }

    _captureSessionController.stopCountdown();
    await _takePhoto();
  }

  Future<void> _setVideoMode(bool videoMode) async {
    if (_isRecording ||
        _isEncrypting ||
        _isCountingDown ||
        _isStartingVideo ||
        _captureControls.isVideoMode == videoMode) {
      return;
    }
    _captureControlsController.setVideoMode(videoMode);
    await applyFlash(_cameraController, _captureControls.flashMode, logTag: 'QuickCaptureScreen');
  }

  void _triggerShutterFlash() {
    setState(() => _showShutterFlash = true);
    Future.delayed(const Duration(milliseconds: 60), () {
      if (mounted) setState(() => _showShutterFlash = false);
    });
  }

  Future<void> _takePhoto() async {
    if (!_cameraController.isInitialized || _isEncrypting || _isTakingPhoto) return;
    _isTakingPhoto = true;

    _triggerShutterFlash();

    setState(() {
      _pendingPhotoCount++;
    });
    _scrollToEndOfTray();

    try {
      await _cameraController.setOrientationDegrees(
        _computeDeviceRotationDegrees(),
      );

      final isFirstMedia = _capturedMedia.isEmpty;
      final result = await _cameraController.capturePhoto();

      if (result.success && result.bytes != null && mounted) {
        HapticFeedback.lightImpact();
        setState(() {
          _capturedMedia.add(
            CapturedMediaItem.photo(
              photoBytes: result.bytes!,
              thumbnailBytes: result.thumbnail ?? result.bytes!,
            ),
          );
          if (isFirstMedia) {
            _phase = _Phase.reviewing;
          }
        });
        _scrollToEndOfTray();
      } else {
        if (mounted) {
          _showErrorToast(
            result.error ?? context.l10n.cameraPhotoCaptureFailedMessage,
          );
        }
      }
    } catch (_) {
      if (mounted) {
        _showErrorToast(context.l10n.cameraPhotoCaptureFailedMessage);
      }
    } finally {
      _isTakingPhoto = false;
      if (mounted) {
        setState(() {
          _pendingPhotoCount = math.max(0, _pendingPhotoCount - 1);
        });
      }
    }
  }

  Future<void> _commitAllMediaToVault(List<CapturedMediaItem> mediaToSave) async {
    if (mediaToSave.isEmpty) return;

    final destination = await Navigator.push<CryptoDestination>(
      context,
      MaterialPageRoute(builder: (_) => const ShareDestinationSheet()),
    );
    if (destination == null || !mounted) return;
    if (!destination.isVault ||
        destination.container == null ||
        destination.relativePath == null) {
      return;
    }

    setState(() => _phase = _Phase.saving);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;

    final container = destination.container!;
    final vaultService = CameraVaultService(
      container: container,
      targetDirPath: destination.relativePath!,
      fileIoApi: _fileIoApi,
      lifecycleApi: _lifecycleApi,
    );

    try {
      String? firstName;
      bool hasVideo = false;

      for (int i = 0; i < mediaToSave.length; i++) {
        final item = mediaToSave[i];
        if (item.isPhoto && item.fullPhotoBytes != null) {
          final name = await vaultService.nextAvailableName(isPhoto: true);
          firstName ??= name;
          final virtualPath = vaultService.buildVirtualPath(name);
          final ok = await _cameraController.savePhotoToVault(
            bytes: item.fullPhotoBytes!,
            volId: container.volId,
            virtualPath: virtualPath,
          );
          if (ok) await vaultService.finalizeVaultWrite(virtualPath);
        } else if (item.isVideo && item.videoPath != null) {
          hasVideo = true;
          var finalVideoPath = item.videoPath!;
          if (item.trimStartMs > 0 || (item.trimEndMs > 0 && item.trimEndMs < item.videoDurationMs)) {
            final trimmed = await _cameraController.trimVideo(
              videoPath: item.videoPath!,
              startMs: item.trimStartMs,
              endMs: item.trimEndMs,
            );
            if (trimmed != null) finalVideoPath = trimmed;
          }
          final name = await vaultService.nextAvailableName(isPhoto: false);
          firstName ??= name;
          final virtualPath = vaultService.buildVirtualPath(name);
          final ok = await _cameraController.saveVideoToVault(
            videoPath: finalVideoPath,
            volId: container.volId,
            virtualPath: virtualPath,
          );
          if (ok) await vaultService.finalizeVaultWrite(virtualPath);
        }
      }

      final settings = await ref.read(appSettingsServiceProvider).loadSettings();
      final shouldRelock = switch (settings.quickActionLockMode) {
        QuickActionLockMode.alwaysLock => true,
        QuickActionLockMode.leaveAsFound => destination.wasInitiallyLocked,
        QuickActionLockMode.leaveOpen => false,
      };

      if (shouldRelock) {
        await _lifecycleApi.lockContainer(container.uri);
      }

      if (mounted) {
        await _quickCaptureApi.showToast(
          context.l10n.quickCaptureSavedToast(firstName ?? 'media', destination.displayName),
        );
        Navigator.pop(context, (savedName: firstName ?? 'media', isVideo: hasVideo));
      }
    } catch (_) {
      if (mounted) {
        _showErrorToast(context.l10n.cameraCouldNotSaveRecordingMessage);
        setState(() => _phase = _Phase.camera);
      }
    }
  }

  Future<void> _startVideoRecording() async {
    if (!_cameraController.isInitialized ||
        _isEncrypting ||
        _isRecording ||
        _isStartingVideo) {
      return;
    }

    _captureSessionController.setStartingVideo(true);
    try {
      final session = await _quickCaptureApi.openSession();
      if (session == null) {
        _showErrorToast(context.l10n.cameraRecordingFailedMessage);
        return;
      }
      _pendingScratchpad = session;

      await _cameraController.setOrientationDegrees(
        _computeDeviceRotationDegrees(),
      );

      final result = await _cameraController.startVideoRecordingToScratchpad(
        sessionToken: session.sessionToken,
        scratchpadPath: session.scratchpadPath,
      );

      if (!result.success) {
        await _quickCaptureApi.discardSession(session.sessionToken);
        _pendingScratchpad = null;
        _showErrorToast(
          result.error ?? context.l10n.cameraRecordingFailedMessage,
        );
        return;
      }

      _recordingStart = DateTime.now();
      _isRecording = true;
      if (!mounted) return;
      _captureSessionController.startRecording();
      unawaited(_fileIoApi.setKeepScreenOn(true));

      _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (!mounted || _recordingStart == null) return;
        final elapsed = DateTime.now().difference(_recordingStart!).inSeconds;
        _captureSessionController.updateTimerText(
          '${(elapsed ~/ 60).toString().padLeft(2, '0')}:${(elapsed % 60).toString().padLeft(2, '0')}',
        );
      });
    } catch (e) {
      _showErrorToast(
        context.l10n.cameraRecordingFailedWithReasonMessage('$e'),
      );
    } finally {
      _captureSessionController.setStartingVideo(false);
      if (_pendingStopAfterStart) {
        _pendingStopAfterStart = false;
        if (_isRecording) _stopVideoRecording();
      }
    }
  }

  Future<void> _stopVideoRecording() async {
    if (!_cameraController.isInitialized || !_isRecording) return;

    _timer?.cancel();
    final startedAt = _recordingStart;
    _recordingStart = null;
    _isRecording = false;

    try {
      final isFirstMedia = _capturedMedia.isEmpty;
      final result = await _cameraController.stopVideoRecordingForReview();
      final elapsedMs = startedAt == null
          ? 9999
          : DateTime.now().difference(startedAt).inMilliseconds;

      final session = _pendingScratchpad;
      if (elapsedMs < 500 || !result.success || result.videoPath == null) {
        if (session != null) {
          await _quickCaptureApi.discardSession(session.sessionToken);
        }
        if (result.videoPath != null) {
          await _cameraController.discardVideo(result.videoPath!);
        }
        _pendingScratchpad = null;
        if (mounted) {
          _showErrorToast(context.l10n.cameraRecordingTooShortMessage);
        }
        return;
      }

      setState(() {
        _capturedMedia.add(
          CapturedMediaItem.video(
            videoPath: result.videoPath!,
            videoDurationMs: result.durationMs,
            thumbnailBytes: result.thumbnail ?? Uint8List(0),
          ),
        );
        if (isFirstMedia) {
          _phase = _Phase.reviewing;
        }
      });
    } catch (e) {
      final session = _pendingScratchpad;
      if (session != null) {
        await _quickCaptureApi.discardSession(session.sessionToken);
      }
      _pendingScratchpad = null;
      if (mounted) {
        _showErrorToast(
          context.l10n.cameraCouldNotSaveRecordingWithReasonMessage('$e'),
        );
      }
    } finally {
      unawaited(_fileIoApi.setKeepScreenOn(false));
    }
  }

  void _discardAllMedia() {
    for (final item in _capturedMedia) {
      if (item.isVideo && item.videoPath != null) {
        _cameraController.discardVideo(item.videoPath!);
      }
    }
    final session = _pendingScratchpad;
    _pendingScratchpad = null;
    if (session != null) {
      unawaited(_quickCaptureApi.discardSession(session.sessionToken));
    }
    setState(() {
      _capturedMedia.clear();
      _phase = _Phase.camera;
      _saveError = null;
    });
  }

  void _showErrorToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red.shade800),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    ref.watch(cameraCaptureControlsProvider(_quickCaptureControlsKey));
    ref.watch(cameraCaptureSessionProvider(_quickCaptureSessionKey));

    final isReviewing = _phase == _Phase.reviewing && _capturedMedia.isNotEmpty;
    final canPop = !isReviewing &&
        !_isRecording &&
        !_isEncrypting &&
        !_isCountingDown &&
        _phase != _Phase.saving &&
        _capturedMedia.isEmpty &&
        _pendingPhotoCount == 0;

    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (isReviewing) {
          setState(() => _phase = _Phase.camera);
        } else if (_capturedMedia.isNotEmpty) {
          HapticFeedback.lightImpact();
          _discardAllMedia();
        }
      },
      child: isReviewing
          ? CameraMediaReviewView(
              initialMedia: _capturedMedia,
              iconTurns: _iconTurns,
              onMediaChanged: (updated) {
                setState(() {
                  _capturedMedia
                    ..clear()
                    ..addAll(updated);
                  if (_capturedMedia.isEmpty) {
                    _phase = _Phase.camera;
                  }
                });
              },
              onDiscard: _discardAllMedia,
              onTakeMoreMedia: () {
                setState(() => _phase = _Phase.camera);
              },
              onSaveMedia: _commitAllMediaToVault,
            )
          : Scaffold(
              backgroundColor: Colors.black,
              body: Stack(
                fit: StackFit.expand,
                children: [
                  if (_isInitialized && _cameraController.textureId != null)
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final bool isLandscapeFrame =
                            constraints.maxWidth > constraints.maxHeight;

                        return GestureDetector(
                          onScaleStart: (_) => _baseZoom = _currentZoom,
                          onScaleUpdate: (d) async {
                            double target = (_baseZoom * d.scale).clamp(
                              _minZoom,
                              _maxZoom,
                            );
                            if (target != _currentZoom) {
                              _captureSessionController.setZoom(target);
                              await applyZoomSilent(_cameraController, target);
                            }
                          },
                          onTapDown: (details) => _onTapToFocus(details, constraints),
                          child: Center(
                            child: CameraPreviewView(
                              textureId: _cameraController.textureId!,
                              previewWidth: _cameraController.previewWidth,
                              previewHeight: _cameraController.previewHeight,
                              sensorOrientation: _cameraController.sensorOrientation,
                              displayRotation: _displayRotation,
                              frameAspectRatio: isLandscapeFrame
                                  ? _captureControls.aspectRatio
                                  : 1 / _captureControls.aspectRatio,
                              showShutterFlash: _showShutterFlash,
                            ),
                          ),
                        );
                      },
                    )
                  else if (_permissionError != null)
                    Center(
                      child: Text(
                        _permissionError!,
                        style: const TextStyle(color: Colors.white),
                      ),
                    )
                  else
                    const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),

                  if (_phase == _Phase.camera)
                    CameraFocusExposureOverlay(
                      focusPoint: _focusPoint,
                      showExposureSlider: _showExposureSlider,
                      currentExposureEv: _currentExposureEv,
                      minExposureEv: _minExposureEv,
                      maxExposureEv: _maxExposureEv,
                      onExposureChanged: (val) async {
                        _captureSessionController.setExposureEv(val);
                        await applyExposureOffsetSilent(_cameraController, val);
                      },
                    ),

                  if (_phase == _Phase.camera) ...[
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: CameraTopControlsBar(
                        isVideoMode: _captureControls.isVideoMode,
                        isRecording: _isRecording,
                        isCountingDown: _isCountingDown,
                        timerText: _timerText,
                        videoQuality: _captureControls.videoQuality,
                        photoResolution: _captureControls.photoResolution,
                        photoResolutions: _captureSession.photoResolutions,
                        videoQualities: _captureSession.videoQualities,
                        selectedAspectRatio: _captureControls.aspectRatio,
                        onAspectRatioChanged: _captureControlsController.selectAspectRatio,
                        timerDelaySeconds: _captureControls.timerDelaySeconds,
                        flashMode: _captureControls.flashMode,
                        iconTurns: _iconTurns,
                        onClose: () {
                          if (_phase == _Phase.saving) return;
                          Navigator.pop(context);
                        },
                        onVideoQualityChanged: _changeQuality,
                        onPhotoResolutionChanged: _changePhotoResolution,
                        onCycleTimerDelay: _captureControlsController.cycleTimerDelay,
                        onCycleFlashMode: () {
                          final nextMode = _captureControlsController.cyclePhotoFlashMode();
                          unawaited(applyFlash(_cameraController, nextMode, logTag: 'QuickCaptureScreen'));
                        },
                      ),
                    ),

                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: _buildBottomControls(),
                    ),

                    if (isLandscape && (_capturedMedia.isNotEmpty || _pendingPhotoCount > 0) && !_isRecording && !_isCountingDown)
                      Positioned(
                        left: 16.0 + MediaQuery.paddingOf(context).left,
                        bottom: 76.0 + MediaQuery.paddingOf(context).bottom,
                        child: _buildCapturedMediaTray(),
                      ),
                  ],

                  if (_isCountingDown)
                    Center(
                      child: buildRotatedWidget(
                        iconTurns: _iconTurns,
                        child: Text(
                          '$_countdownValue',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 120,
                            shadows: [Shadow(blurRadius: 20)],
                          ),
                        ),
                      ),
                    ),

                  if (_isEncrypting || _phase == _Phase.saving)
                    Container(
                      color: Colors.black54,
                      child: Center(
                        child: buildRotatedWidget(
                          iconTurns: _iconTurns,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(color: Colors.white),
                              const SizedBox(height: 20),
                              Text(
                                _phase == _Phase.saving
                                    ? context.l10n.savingToVault
                                    : _busyLabel,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _buildCapturedMediaTray() {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    final totalCount = _capturedMedia.length + _pendingPhotoCount;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: isLandscape ? 160 : 180),
            child: SingleChildScrollView(
              controller: _trayScrollController,
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (int i = 0; i < _capturedMedia.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 2, right: 8, left: 4),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              setState(() => _phase = _Phase.reviewing);
                            },
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                width: 44,
                                height: 44,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    _capturedMedia[i].thumbnailBytes.isNotEmpty
                                        ? Image.memory(
                                            _capturedMedia[i].thumbnailBytes,
                                            fit: BoxFit.cover,
                                          )
                                        : Container(color: Colors.grey.shade900),
                                    if (_capturedMedia[i].isVideo)
                                      Center(
                                        child: Container(
                                          padding: const EdgeInsets.all(3),
                                          decoration: const BoxDecoration(
                                            color: Colors.black54,
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 14),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            top: -10,
                            right: -10,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                HapticFeedback.lightImpact();
                                final removed = _capturedMedia.removeAt(i);
                                if (removed.isVideo && removed.videoPath != null) {
                                  _cameraController.discardVideo(removed.videoPath!);
                                }
                                setState(() {});
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: Container(
                                  width: 20,
                                  height: 20,
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.9),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 1.2),
                                  ),
                                  child: const Center(
                                    child: Icon(Icons.close_rounded, color: Colors.white, size: 13),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  for (int p = 0; p < _pendingPhotoCount; p++)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 2, right: 8, left: 4),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.white10,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.amber.withValues(alpha: 0.8), width: 1.5),
                        ),
                        child: const Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.amber,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.amber,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: _capturedMedia.isNotEmpty
                ? () {
                    setState(() => _phase = _Phase.reviewing);
                  }
                : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$totalCount', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(width: 4),
                const Icon(Icons.arrow_forward_rounded, size: 14),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomControls() {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.black54, Colors.transparent],
        ),
      ),
      padding: EdgeInsets.only(
        bottom: isLandscape ? 12 : 32,
        top: isLandscape ? 8 : 16,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isLandscape && (_capturedMedia.isNotEmpty || _pendingPhotoCount > 0) && !_isRecording && !_isCountingDown)
              _buildCapturedMediaTray(),

            if (!_isRecording && !_isCountingDown) ...[
              CameraZoomIndicator(
                currentZoom: _currentZoom,
                minZoom: _minZoom,
                maxZoom: _maxZoom,
                iconTurns: _iconTurns,
                onSetZoom: (zoom) async {
                  _captureSessionController.setZoom(zoom);
                  await applyZoomLogged(_cameraController, zoom, logTag: 'QuickCaptureScreen');
                },
              ),
              SizedBox(height: isLandscape ? 6 : 16),
            ],
            SizedBox(height: isLandscape ? 8 : 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                buildRotatedWidget(
                  iconTurns: _iconTurns,
                  child: IconButton(
                    icon: const Icon(
                      Icons.flip_camera_ios_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                    onPressed: _flipCamera,
                  ),
                ),
                GestureDetector(
                  onTap: _onCaptureClicked,
                  child: Container(
                    width: 76,
                    height: 76,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                    ),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOut,
                      width: _captureControls.isVideoMode && _isRecording ? 30 : 60,
                      height: _captureControls.isVideoMode && _isRecording ? 30 : 60,
                      decoration: BoxDecoration(
                        color: _captureControls.isVideoMode
                            ? Colors.red
                            : Colors.white,
                        borderRadius: BorderRadius.circular(
                          _captureControls.isVideoMode && _isRecording ? 8 : 30,
                        ),
                      ),
                    ),
                  ),
                ),
                if (!_isRecording && !_isCountingDown)
                  _buildModeToggle()
                else
                  const SizedBox(width: 48),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeToggle() {
    Widget modeButton({
      required bool selected,
      required IconData icon,
      required VoidCallback onTap,
    }) {
      return GestureDetector(
        onTap: onTap,
        child: buildRotatedWidget(
          iconTurns: _iconTurns,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? Colors.amber : Colors.black45,
            ),
            child: Icon(
              icon,
              color: selected ? Colors.black : Colors.white,
              size: 20,
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        modeButton(
          selected: !_captureControls.isVideoMode,
          icon: Icons.photo_camera_rounded,
          onTap: () => _setVideoMode(false),
        ),
        const SizedBox(height: 10),
        modeButton(
          selected: _captureControls.isVideoMode,
          icon: Icons.videocam_rounded,
          onTap: () => _setVideoMode(true),
        ),
      ],
    );
  }
}