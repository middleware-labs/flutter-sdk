// Licensed under the Apache License, Version 2.0

import 'dart:async';

import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../flutterrific_otel.dart';

/// Cardinal direction for scroll / swipe auto-capture (string values match
/// [InteractionType.gestureDirection] usage elsewhere in this SDK).
enum UserInteractionPanDirection {
  up,
  down,
  left,
  right;

  String get value => name;
}

/// Global pointer-based user interaction capture (similar to Coralogix
/// `CxInteractionTracker`): taps, scrolls, and swipes without wrapper widgets.
///
/// When [FlutterOTel.initialize] is called with `enableAutomaticUserInteractions:
/// true`, [initialize] is invoked after OpenTelemetry is ready. Call
/// [setEnabled] to toggle reporting at runtime without removing the pointer
/// route (mirrors reading `userActions` from options on each event).
class AutomaticUserInteractionTracker {
  AutomaticUserInteractionTracker._({
    required this.tapThreshold,
    required this.debug,
  });

  static AutomaticUserInteractionTracker? _instance;
  static bool _initialized = false;

  /// When false, pointer state is cleared and no spans are emitted.
  static bool _reportingEnabled = true;

  final double tapThreshold;
  final bool debug;

  final Map<int, _PointerState> _pointerStates = <int, _PointerState>{};

  /// Whether automatic interaction spans are emitted (checked on every pointer
  /// event so disabling takes effect immediately).
  static bool get isReportingEnabled => _reportingEnabled;

  /// Toggle reporting at runtime (parity with reading `userActions` from SDK
  /// options on each event).
  static void setReportingEnabled(bool value) {
    _reportingEnabled = value;
  }

  static void initialize({
    double tapThreshold = 20,
    bool debug = false,
  }) {
    if (_initialized) {
      return;
    }
    _instance = AutomaticUserInteractionTracker._(
      tapThreshold: tapThreshold,
      debug: debug,
    );
    _instance!._startListening();
    _initialized = true;
    if (debug) {
      debugPrint('[AutomaticUserInteractionTracker] Initialized');
    }
  }

  static void shutdown() {
    _instance?._stopListening();
    _instance = null;
    _initialized = false;
    _reportingEnabled = true;
  }

  static bool get isInitialized => _initialized;

  void _log(String message) {
    if (debug) {
      debugPrint('[AutomaticUserInteractionTracker] $message');
    }
  }

  void _startListening() {
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handlePointerEvent);
    _log('Listening to pointer events');
  }

  void _stopListening() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(
      _handlePointerEvent,
    );
    _pointerStates.clear();
    _log('Stopped listening to pointer events');
  }

  void _handlePointerEvent(PointerEvent event) {
    if (!_reportingEnabled) {
      _pointerStates.remove(event.pointer);
      return;
    }
    if (event is PointerDownEvent) {
      _handlePointerDown(event);
    } else if (event is PointerMoveEvent) {
      _handlePointerMove(event);
    } else if (event is PointerUpEvent) {
      _handlePointerUp(event);
    } else if (event is PointerCancelEvent) {
      _handlePointerCancel(event);
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    final isSwipe = _isSwipeContext(event.position);
    _pointerStates[event.pointer] = _PointerState(
      startPosition: event.position,
      startTime: event.timeStamp,
      lastPosition: event.position,
      lastTime: event.timeStamp,
      isSwipeContext: isSwipe,
    );
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final state = _pointerStates[event.pointer];
    if (state == null) {
      return;
    }
    state.lastPosition = event.position;
    state.lastTime = event.timeStamp;
    state.hasMoved = true;
  }

  void _handlePointerUp(PointerUpEvent event) {
    final state = _pointerStates.remove(event.pointer);
    if (state == null) {
      return;
    }
    final totalDelta = event.position - state.startPosition;
    final dx = totalDelta.dx;
    final dy = totalDelta.dy;
    final displacement = totalDelta.distance;

    if (displacement < tapThreshold) {
      final widgetInfo = _extractWidgetInfo(event.position);
      final innerText = _nonEmpty(widgetInfo.text);
      _reportTap(
        targetElement: widgetInfo.targetElement,
        elementClasses: widgetInfo.widgetClassName,
        innerText: innerText,
        x: event.position.dx,
        y: event.position.dy,
      );
    } else {
      final direction = _directionFromDisplacement(dx, dy);
      final type =
          state.isSwipeContext ? InteractionType.swipe : InteractionType.scroll;
      _reportPan(
        interactionType: type,
        direction: direction,
      );
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    final state = _pointerStates.remove(event.pointer);
    if (state == null) {
      return;
    }
    if (state.hasMoved) {
      final totalDelta = state.lastPosition - state.startPosition;
      final dx = totalDelta.dx;
      final dy = totalDelta.dy;
      final displacement = totalDelta.distance;
      if (displacement >= tapThreshold) {
        final direction = _directionFromDisplacement(dx, dy);
        final type =
            state.isSwipeContext
                ? InteractionType.swipe
                : InteractionType.scroll;
        _reportPan(
          interactionType: type,
          direction: direction,
        );
      }
    }
  }

  UserInteractionPanDirection _directionFromDisplacement(double dx, double dy) {
    if (dy.abs() >= dx.abs()) {
      return dy < 0 ? UserInteractionPanDirection.up : UserInteractionPanDirection.down;
    }
    return dx < 0 ? UserInteractionPanDirection.left : UserInteractionPanDirection.right;
  }

  bool _isSwipeContext(Offset position) {
    try {
      final checked = <Element>{};
      final elements = _findElementsAtPosition(position);
      for (final element in elements) {
        if (checked.contains(element)) {
          continue;
        }
        checked.add(element);
        var found = false;
        element.visitAncestorElements((ancestor) {
          final w = ancestor.widget;
          if (w is PageView || w is Dismissible || w is TabBarView) {
            found = true;
            return false;
          }
          return true;
        });
        if (found) {
          return true;
        }
      }
    } catch (e) {
      _log('Error checking swipe context: $e');
    }
    return false;
  }

  void _reportTap({
    required String targetElement,
    required String elementClasses,
    String? innerText,
    required double x,
    required double y,
  }) {
    unawaited(
      _report(() {
        final route = FlutterOTel.currentInteractionRouteName;
        final attrs = <String, Object>{
          'ui.auto.capture': true,
          'ui.auto.x': x,
          'ui.auto.y': y,
          'ui.auto.widget_class': elementClasses,
          if (innerText != null) 'ui.auto.target_text': innerText,
        };
        FlutterOTel.tracer.recordUserInteraction(
          route,
          InteractionType.click,
          targetName: targetElement,
          attributes: attrs.toAttributes(),
        );
      }),
    );
  }

  void _reportPan({
    required InteractionType interactionType,
    required UserInteractionPanDirection direction,
  }) {
    unawaited(
      _report(() {
        final route = FlutterOTel.currentInteractionRouteName;
        FlutterOTel.tracer.recordUserInteraction(
          route,
          interactionType,
          targetName: 'Screen',
          attributes:
              {InteractionType.gestureDirection.key: direction.value}.toAttributes(),
        );
      }),
    );
  }

  Future<void> _report(void Function() body) async {
    try {
      await Future<void>.microtask(body);
    } catch (e, s) {
      _log('Error reporting interaction: $e\n$s');
    }
  }

  _WidgetInfo _extractWidgetInfo(Offset position) {
    try {
      final hitTestResult = HitTestResult();
      _hitTestAt(position, hitTestResult);

      final allHitElements = <Element>[];
      for (final entry in hitTestResult.path) {
        final target = entry.target;
        if (target is RenderObject) {
          final debugCreator = target.debugCreator;
          if (debugCreator is DebugCreator) {
            allHitElements.add(debugCreator.element);
          }
        }
      }

      if (allHitElements.isEmpty) {
        final fallback = _findElementsAtPosition(position);
        allHitElements.addAll(fallback);
      }

      Element? bestInteractive;
      Element? genericFallback;

      for (var i = 0; i < allHitElements.length; i++) {
        final element = allHitElements[i];
        var current = element;
        while (true) {
          final className = current.widget.runtimeType.toString();
          final cleanName =
              className.startsWith('_') ? className.substring(1) : className;
          final isDetecting =
              _isDetectingElement(className) ||
              _isDetectingElement(cleanName) ||
              _isButtonWidget(current.widget);

          if (isDetecting) {
            if (_isGenericGestureWidget(className)) {
              genericFallback ??= current;
            } else {
              bestInteractive = current;
              break;
            }
          }
          Element? parent;
          current.visitAncestorElements((ancestor) {
            parent = ancestor;
            return false;
          });
          if (parent == null) {
            break;
          }
          current = parent!;
        }
        if (bestInteractive != null) {
          break;
        }
      }

      if (bestInteractive == null && allHitElements.isNotEmpty) {
        final firstWidget = allHitElements.first.widget;
        if (firstWidget is Listener) {
          bestInteractive = _findDialogContentAtPosition(position);
        }
      }

      bestInteractive ??= genericFallback;
      final deepest = bestInteractive ?? (allHitElements.isEmpty ? null : allHitElements.first);

      if (deepest == null) {
        return _WidgetInfo(targetElement: 'Screen', widgetClassName: 'Screen');
      }

      String? elementClassName;
      if (bestInteractive != null) {
        final raw = bestInteractive.widget.runtimeType.toString();
        elementClassName =
            raw.startsWith('_') ? raw.substring(1) : raw;
      }

      String? textContent;
      String? semanticsLabel;

      if (bestInteractive != null) {
        textContent = _findTextInChildren(bestInteractive);
      }

      if (textContent == null) {
        var current = deepest;
        while (true) {
          final widget = current.widget;
          if (textContent == null) {
            if (widget is Text) {
              textContent = _nonEmpty(widget.data ?? widget.textSpan?.toPlainText());
            } else if (widget is RichText) {
              textContent = _nonEmpty(widget.text.toPlainText());
            }
          }
          if (semanticsLabel == null) {
            if (widget is Semantics) {
              semanticsLabel = _nonEmpty(widget.properties.label);
            } else if (widget is IconButton) {
              semanticsLabel = _nonEmpty(widget.tooltip);
            } else if (widget is Tooltip) {
              semanticsLabel = _nonEmpty(widget.message);
            }
          }
          if (textContent != null) {
            break;
          }
          Element? parent;
          current.visitAncestorElements((ancestor) {
            parent = ancestor;
            return false;
          });
          if (parent == null) {
            break;
          }
          current = parent!;
        }
      }

      final targetElement = elementClassName ?? 'Screen';
      return _WidgetInfo(
        targetElement: targetElement,
        text: textContent,
        accessibilityLabel: semanticsLabel,
        widgetClassName: targetElement,
      );
    } catch (e) {
      _log('Error extracting widget info: $e');
    }

    return _WidgetInfo(targetElement: 'Screen', widgetClassName: 'Screen');
  }

  bool _isDetectingElement(String className) {
    const detecting = <String>{
      'Button',
      'ElevatedButton',
      'TextButton',
      'OutlinedButton',
      'FilledButton',
      'IconButton',
      'FloatingActionButton',
      'PopupMenuButton',
      'DropdownButton',
      'ButtonStyleButton',
      'Card',
      'ListTile',
      'Tab',
      'Chip',
      'Dismissible',
      'Switch',
      'Checkbox',
      'Radio',
      'Slider',
      'BottomNavigationBar',
      'NavigationRail',
      'TabBar',
      'AlertDialog',
      'Dialog',
      'SimpleDialog',
      'InkWell',
      'GestureDetector',
      'InkResponse',
    };
    return detecting.contains(className);
  }

  bool _isButtonWidget(Widget widget) {
    return widget is ElevatedButton ||
        widget is TextButton ||
        widget is OutlinedButton ||
        widget is FilledButton ||
        widget is IconButton ||
        widget is FloatingActionButton ||
        widget is PopupMenuButton ||
        widget is DropdownButton ||
        widget is BackButton ||
        widget is CloseButton ||
        widget is ButtonStyleButton;
  }

  bool _isGenericGestureWidget(String className) {
    const generic = {'GestureDetector', 'InkWell', 'InkResponse'};
    return generic.contains(className);
  }

  List<Element> _findElementsAtPosition(Offset position) {
    final elementsAtPosition = <Element>[];
    void visitor(Element element) {
      final ro = element.renderObject;
      if (ro is RenderBox && ro.attached) {
        try {
          final local = ro.globalToLocal(position);
          if (ro.paintBounds.contains(local)) {
            elementsAtPosition.add(element);
          }
        } catch (_) {}
      }
      element.visitChildren(visitor);
    }

    final root = WidgetsBinding.instance.rootElement;
    root?.visitChildren(visitor);
    return elementsAtPosition;
  }

  void _hitTestAt(Offset position, HitTestResult result) {
    final binding = WidgetsBinding.instance;
    try {
      final views = binding.platformDispatcher.views;
      if (views.isNotEmpty) {
        binding.hitTestInView(result, position, views.first.viewId);
        return;
      }
    } catch (e) {
      _log('hitTestInView failed: $e');
    }
    try {
      final renderViews = RendererBinding.instance.renderViews;
      if (renderViews.isNotEmpty) {
        renderViews.first.hitTest(result, position: position);
      }
    } catch (e) {
      _log('renderViews.hitTest failed: $e');
    }
  }

  String? _nonEmpty(String? s) {
    if (s == null) {
      return null;
    }
    final trimmed = s.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final hasRealText =
        !trimmed.codeUnits.every((c) => c >= 0xe000 && c <= 0xf8ff);
    if (!hasRealText) {
      return null;
    }
    return trimmed;
  }

  String? _findTextInChildren(Element element) {
    String? foundText;

    void search(Element el) {
      if (foundText != null) {
        return;
      }
      final widget = el.widget;
      if (widget is Text) {
        foundText = _nonEmpty(widget.data ?? widget.textSpan?.toPlainText());
      } else if (widget is RichText) {
        foundText = _nonEmpty(widget.text.toPlainText());
      }
      if (foundText == null) {
        el.visitChildren(search);
      }
    }

    element.visitChildren(search);
    return foundText;
  }

  Element? _findDialogContentAtPosition(Offset position) {
    try {
      final root = WidgetsBinding.instance.rootElement;
      if (root == null) {
        return null;
      }
      Element? bestMatch;
      var bestArea = double.infinity;

      void searchElement(Element element) {
        final ro = element.renderObject;
        if (ro is RenderBox && ro.hasSize) {
          try {
            final transform = ro.getTransformTo(null);
            final bounds = MatrixUtils.transformRect(
              transform,
              Offset.zero & ro.size,
            );
            if (bounds.contains(position)) {
              final widget = element.widget;
              final className = widget.runtimeType.toString();
              final cleanName =
                  className.startsWith('_') ? className.substring(1) : className;
              final isInteractive =
                  _isDetectingElement(className) ||
                  _isDetectingElement(cleanName) ||
                  _isButtonWidget(widget);
              if (isInteractive && !_isGenericGestureWidget(className)) {
                final area = bounds.width * bounds.height;
                if (area < bestArea) {
                  bestArea = area;
                  bestMatch = element;
                }
              }
            }
          } catch (_) {}
        }
        element.visitChildren(searchElement);
      }

      searchElement(root);
      return bestMatch;
    } catch (e) {
      _log('Error finding dialog content: $e');
      return null;
    }
  }
}

class _WidgetInfo {
  _WidgetInfo({
    required this.targetElement,
    this.text,
    this.accessibilityLabel,
    this.widgetClassName = 'Unknown',
  });

  final String targetElement;
  final String? text;
  final String? accessibilityLabel;
  final String widgetClassName;
}

class _PointerState {
  _PointerState({
    required this.startPosition,
    required this.startTime,
    required this.lastPosition,
    required this.lastTime,
    this.isSwipeContext = false,
  });

  final Offset startPosition;
  final Duration startTime;
  Offset lastPosition;
  Duration lastTime;
  bool hasMoved = false;
  final bool isSwipeContext;
}
