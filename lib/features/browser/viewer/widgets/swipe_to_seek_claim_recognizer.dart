import 'package:flutter/gestures.dart';

/// Claims a horizontal drag across the screen for seeking in the video player,
/// resolving eagerly in the gesture arena before parent scrollables can claim it.
class SwipeToSeekClaimRecognizer extends HorizontalDragGestureRecognizer {
  SwipeToSeekClaimRecognizer({required this.canClaim})
      : super(supportedDevices: const {PointerDeviceKind.touch}) {
    onStart = (_) {};
  }

  final bool Function() canClaim;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      canClaim() && super.isPointerAllowed(event);

  @override
  void handleEvent(PointerEvent event) {
    // Eagerly resolve as accepted once horizontal movement begins,
    // locking out ancestor scrollables before touch-slop is crossed.
    if (event is PointerMoveEvent) {
      final dx = event.delta.dx.abs();
      final dy = event.delta.dy.abs();
      if (dx > dy && dx > 2.0) {
        resolve(GestureDisposition.accepted);
      }
    }
    super.handleEvent(event);
  }

  void abort() => resolve(GestureDisposition.rejected);
}
