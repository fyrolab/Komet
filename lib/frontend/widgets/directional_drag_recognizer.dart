import 'package:flutter/gestures.dart';

class DirectionalDragRecognizer extends HorizontalDragGestureRecognizer {
  DirectionalDragRecognizer({
    required this.direction,
    this.minAcceptDistance = kTouchSlop,
    super.debugOwner,
  }) {
    onlyAcceptDragOnThreshold = true;
    dragStartBehavior = DragStartBehavior.down;
  }

  final double direction;
  final double minAcceptDistance;
  bool Function()? enabled;

  final Map<int, Offset> _initialPositions = {};
  final Map<int, Offset> _currentDeltas = {};
  bool _directionLocked = false;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      (enabled?.call() ?? true) && super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _initialPositions[event.pointer] = event.position;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      final initial = _initialPositions[event.pointer];
      if (initial != null) {
        final delta = event.position - initial;
        _currentDeltas[event.pointer] = delta;
        if (!_directionLocked &&
            (delta.dx * direction < -kTouchSlop ||
                (delta.dy.abs() > kTouchSlop &&
                    delta.dy.abs() > delta.dx.abs()))) {
          resolvePointer(event.pointer, GestureDisposition.rejected);
          return;
        }
      }
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    if (!super.hasSufficientGlobalDistanceToAccept(
      pointerDeviceKind,
      deviceTouchSlop,
    )) {
      return false;
    }
    _directionLocked = _currentDeltas.values.any(
      (delta) =>
          delta.dx * direction >= minAcceptDistance &&
          delta.dx.abs() > delta.dy.abs(),
    );
    return _directionLocked;
  }

  void _cleanup(int pointer) {
    _initialPositions.remove(pointer);
    _currentDeltas.remove(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _cleanup(pointer);
    _directionLocked = false;
    super.didStopTrackingLastPointer(pointer);
  }

  @override
  void rejectGesture(int pointer) {
    _cleanup(pointer);
    super.rejectGesture(pointer);
  }
}

class RightwardDragRecognizer extends DirectionalDragRecognizer {
  RightwardDragRecognizer({super.debugOwner}) : super(direction: 1);
}

class LeftwardDragRecognizer extends DirectionalDragRecognizer {
  LeftwardDragRecognizer({super.debugOwner}) : super(direction: -1);
}
