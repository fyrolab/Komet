import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/cupertino.dart';

import 'directional_drag_recognizer.dart';

class SwipeRoute<T> extends PageRoute<T> {
  SwipeRoute({
    required this.builder,
    super.settings,
    super.fullscreenDialog,
    this.maintainState = true,
  });

  final WidgetBuilder builder;

  @override
  final bool maintainState;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 400);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 400);

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      (context, animation, secondaryAnimation, allowSnapshotting, child) =>
          CupertinoPageTransition(
            primaryRouteAnimation: kAlwaysCompleteAnimation,
            secondaryRouteAnimation: secondaryAnimation,
            linearTransition: Navigator.of(context).userGestureInProgress,
            child: child ?? const SizedBox.shrink(),
          );

  @override
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) {
    if (nextRoute is PageRoute && nextRoute.fullscreenDialog) return false;
    return nextRoute is SwipeRoute ||
        nextRoute is CupertinoRouteTransitionMixin ||
        (nextRoute is ModalRoute && nextRoute.delegatedTransition != null);
  }

  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) =>
      previousRoute is PageRoute && !fullscreenDialog;

  @override
  bool get popGestureInProgress => navigator?.userGestureInProgress ?? false;

  _SwipeBackController<T>? _gestureController;

  @override
  bool get popGestureEnabled {
    if (fullscreenDialog || !isCurrent) return false;
    if (isFirst) return false;
    if (willHandlePopInternally) return false;
    if (popDisposition == RoutePopDisposition.doNotPop) return false;
    if (animation?.status != AnimationStatus.completed) return false;
    if (secondaryAnimation?.status != AnimationStatus.dismissed) return false;
    if (popGestureInProgress) return false;
    return true;
  }

  _SwipeBackController<T> _startPopGesture() {
    final gesture = _SwipeBackController<T>(
      navigator: navigator!,
      controller: controller!,
      isActive: () => isActive,
      isCurrent: () => isCurrent,
      canPop: () => popDisposition != RoutePopDisposition.doNotPop,
    );
    _gestureController = gesture;
    gesture._onEnd = () {
      if (_gestureController == gesture) {
        _gestureController = null;
      }
    };
    navigator!.didStartUserGesture();
    return gesture;
  }

  @override
  void dispose() {
    _gestureController?.dispose();
    super.dispose();
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      child: builder(context),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _SwipeBackGestureDetector<T>(
      enabledCallback: () => popGestureEnabled,
      onStartPopGesture: _startPopGesture,
      child: CupertinoPageTransition(
        primaryRouteAnimation: animation,
        secondaryRouteAnimation: secondaryAnimation,
        linearTransition: popGestureInProgress,
        child: child,
      ),
    );
  }
}

Future<T?> pushSwipeable<T>(
  BuildContext context,
  WidgetBuilder builder, {
  RouteSettings? settings,
}) {
  return Navigator.of(
    context,
  ).push<T>(SwipeRoute<T>(builder: builder, settings: settings));
}

class _SwipeBackGestureDetector<T> extends StatefulWidget {
  const _SwipeBackGestureDetector({
    required this.enabledCallback,
    required this.onStartPopGesture,
    required this.child,
  });

  final ValueGetter<bool> enabledCallback;
  final ValueGetter<_SwipeBackController<T>> onStartPopGesture;
  final Widget child;

  @override
  State<_SwipeBackGestureDetector<T>> createState() =>
      _SwipeBackGestureDetectorState<T>();
}

class _SwipeBackGestureDetectorState<T>
    extends State<_SwipeBackGestureDetector<T>> {
  _SwipeBackController<T>? _backController;
  double _width = 0;

  void _handleStart(DragStartDetails details) {
    if (!widget.enabledCallback()) return;
    _width = context.size?.width ?? MediaQuery.of(context).size.width;
    if (_width <= 0) _width = 1.0;
    FocusManager.instance.primaryFocus?.unfocus();
    _backController = widget.onStartPopGesture();
  }

  void _handleUpdate(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0.0;
    _backController?.dragUpdate(delta / _width);
  }

  void _handleEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dx / _width;
    _backController?.dragEnd(velocity);
    _backController = null;
  }

  void _handleCancel() {
    _backController?.dragEnd(0.0, cancelled: true);
    _backController = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerCancel: (_) => _handleCancel(),
      child: RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: <Type, GestureRecognizerFactory>{
          RightwardDragRecognizer:
              GestureRecognizerFactoryWithHandlers<RightwardDragRecognizer>(
                () => RightwardDragRecognizer(debugOwner: this),
                (instance) {
                  instance
                    ..enabled = widget.enabledCallback
                    ..onStart = _handleStart
                    ..onUpdate = _handleUpdate
                    ..onEnd = _handleEnd
                    ..onCancel = _handleCancel;
                },
              ),
        },
        child: widget.child,
      ),
    );
  }
}

class _SwipeBackController<T> {
  _SwipeBackController({
    required this.navigator,
    required this.controller,
    required this.isActive,
    required this.isCurrent,
    required this.canPop,
  });

  final NavigatorState navigator;
  final AnimationController controller;
  final ValueGetter<bool> isActive;
  final ValueGetter<bool> isCurrent;
  final ValueGetter<bool> canPop;
  VoidCallback? _onEnd;
  AnimationStatusListener? _statusListener;
  bool _ended = false;

  static const double _kMinFlingVelocity = 1.0;

  void dragUpdate(double delta) {
    controller.value -= delta;
  }

  void dragEnd(double velocity, {bool cancelled = false}) {
    const animationCurve = Curves.fastEaseInToSlowEaseOut;
    final bool animateForward;

    if (!isCurrent()) {
      animateForward = isActive();
    } else if (cancelled || !canPop()) {
      animateForward = true;
    } else if (velocity.abs() >= _kMinFlingVelocity) {
      animateForward = velocity <= 0;
    } else {
      animateForward = controller.value > 0.5;
    }

    if (animateForward) {
      final forwardMs = math.min(
        lerpDouble(800, 0, controller.value)!.floor(),
        300,
      );
      controller.animateTo(
        1.0,
        duration: Duration(milliseconds: forwardMs),
        curve: animationCurve,
      );
    } else {
      if (isCurrent()) navigator.pop();
      if (controller.isAnimating) {
        final backMs = math.min(
          lerpDouble(0, 800, controller.value)!.floor(),
          300,
        );
        controller.animateBack(
          0.0,
          duration: Duration(milliseconds: backMs),
          curve: animationCurve,
        );
      }
    }

    if (controller.isAnimating) {
      _statusListener = (status) {
        if (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) {
          _finish();
        }
      };
      controller.addStatusListener(_statusListener!);
    } else {
      _finish();
    }
  }

  void _finish() {
    if (_ended) return;
    _ended = true;
    final listener = _statusListener;
    if (listener != null) controller.removeStatusListener(listener);
    _statusListener = null;
    _onEnd?.call();
    if (navigator.mounted) navigator.didStopUserGesture();
  }

  void dispose() {
    if (_ended) return;
    _ended = true;
    final listener = _statusListener;
    if (listener != null) controller.removeStatusListener(listener);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator.mounted) navigator.didStopUserGesture();
    });
  }
}
