import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultexplorer/features/camera/camera_capture_controls_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  final mockStore = <String, String>{};

  setUp(() {
    mockStore.clear();
    CameraCaptureControls.cachedStates.clear();
    CameraCaptureControls.storageReadOverride = (key) async => mockStore[key];
    CameraCaptureControls.storageWriteOverride = (key, val) async {
      mockStore[key] = val;
    };
    container = ProviderContainer();
  });

  tearDown(() {
    CameraCaptureControls.storageReadOverride = null;
    CameraCaptureControls.storageWriteOverride = null;
    container.dispose();
  });

  group('CameraCaptureControls controller', () {
    test('starts with the photo defaults', () {
      final state = container.read(cameraCaptureControlsProvider('session-a'));

      expect(state.isVideoMode, isFalse);
      expect(state.flashMode, 'auto');
      expect(state.videoQuality, 'fhd');
      expect(state.photoResolution, 'max');
      expect(state.timerDelaySeconds, 0);
      expect(state.aspectRatio, 4 / 3);
      expect(state.preferredFacing, 'back');
    });

    test('owns the video mode and corresponding flash default', () {
      final controller = container.read(
        cameraCaptureControlsProvider('session-a').notifier,
      );

      controller.setVideoMode(true);
      var state = container.read(cameraCaptureControlsProvider('session-a'));
      expect(state.isVideoMode, isTrue);
      expect(state.flashMode, 'off');

      controller.setVideoMode(false);
      state = container.read(cameraCaptureControlsProvider('session-a'));
      expect(state.isVideoMode, isFalse);
      expect(state.flashMode, 'auto');
    });

    test('cycles timer and photo flash settings', () {
      final controller = container.read(
        cameraCaptureControlsProvider('session-a').notifier,
      );

      controller.cycleTimerDelay();
      expect(
        container.read(cameraCaptureControlsProvider('session-a')).timerDelaySeconds,
        3,
      );
      controller.cycleTimerDelay();
      expect(
        container.read(cameraCaptureControlsProvider('session-a')).timerDelaySeconds,
        10,
      );
      controller.cycleTimerDelay();
      expect(
        container.read(cameraCaptureControlsProvider('session-a')).timerDelaySeconds,
        0,
      );

      expect(controller.cyclePhotoFlashMode(), 'on');
      expect(controller.cyclePhotoFlashMode(), 'off');
      expect(controller.cyclePhotoFlashMode(), 'auto');
    });

    test('keeps controls isolated by camera screen session', () {
      container
          .read(cameraCaptureControlsProvider('session-a').notifier)
          .selectVideoQuality('uhd');
      container
          .read(cameraCaptureControlsProvider('session-b').notifier)
          .setVideoMode(true);

      expect(
        container.read(cameraCaptureControlsProvider('session-a')).videoQuality,
        'uhd',
      );
      expect(
        container.read(cameraCaptureControlsProvider('session-a')).isVideoMode,
        isFalse,
      );
      expect(
        container.read(cameraCaptureControlsProvider('session-b')).videoQuality,
        'fhd',
      );
      expect(
        container.read(cameraCaptureControlsProvider('session-b')).isVideoMode,
        isTrue,
      );
    });

    test('persists camera settings across sessions', () async {
      final controllerA = container.read(
        cameraCaptureControlsProvider('camera_capture').notifier,
      );

      controllerA.selectVideoQuality('uhd');
      controllerA.selectPhotoResolution('high');
      controllerA.selectAspectRatio(16 / 9);
      controllerA.setPreferredFacing('front');
      controllerA.cycleTimerDelay();
      controllerA.cyclePhotoFlashMode();
      controllerA.setVideoMode(true);

      final stateA = container.read(cameraCaptureControlsProvider('camera_capture'));
      expect(stateA.videoQuality, 'uhd');
      expect(stateA.photoResolution, 'high');
      expect(stateA.aspectRatio, 16 / 9);
      expect(stateA.preferredFacing, 'front');
      expect(stateA.timerDelaySeconds, 3);
      expect(stateA.flashMode, 'off');
      expect(stateA.isVideoMode, isTrue);

      CameraCaptureControls.cachedStates.clear();
      final newContainer = ProviderContainer();
      addTearDown(newContainer.dispose);

      final controllerB = newContainer.read(
        cameraCaptureControlsProvider('camera_capture').notifier,
      );
      await controllerB.loadPersisted();

      final stateB = newContainer.read(cameraCaptureControlsProvider('camera_capture'));
      expect(stateB.videoQuality, 'uhd');
      expect(stateB.photoResolution, 'high');
      expect(stateB.aspectRatio, 16 / 9);
      expect(stateB.preferredFacing, 'front');
      expect(stateB.timerDelaySeconds, 3);
      expect(stateB.flashMode, 'off');
      expect(stateB.isVideoMode, isTrue);
    });
  });
}