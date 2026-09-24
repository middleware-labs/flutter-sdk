// Licensed under the Apache License, Version 2.0

import 'dart:async';

import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../flutterrific_otel.dart';
import '../web/web_instrumentation.dart';
import '../web/web_utils.dart' show RageClickDetector;

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

  static void initialize({double tapThreshold = 20, bool debug = false}) {
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
    // Nothing is looked up here: pointer down is the hot path, and whether
    // the gesture is a swipe only matters once it turns out to be a pan.
    _pointerStates[event.pointer] = _PointerState(
      startPosition: event.position,
      startTime: event.timeStamp,
      lastPosition: event.position,
      lastTime: event.timeStamp,
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
        xpath: widgetInfo.xpath,
        innerText: innerText,
        x: event.position.dx,
        y: event.position.dy,
        pointerKind: event.kind,
        downAt: state.downAt,
      );
    } else {
      final direction = _directionFromDisplacement(dx, dy);
      final type =
          _isSwipeContext(state.startPosition)
              ? InteractionType.swipe
              : InteractionType.scroll;
      _reportPan(interactionType: type, direction: direction);
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
            _isSwipeContext(state.startPosition)
                ? InteractionType.swipe
                : InteractionType.scroll;
        _reportPan(interactionType: type, direction: direction);
      }
    }
  }

  UserInteractionPanDirection _directionFromDisplacement(double dx, double dy) {
    if (dy.abs() >= dx.abs()) {
      return dy < 0
          ? UserInteractionPanDirection.up
          : UserInteractionPanDirection.down;
    }
    return dx < 0
        ? UserInteractionPanDirection.left
        : UserInteractionPanDirection.right;
  }

  bool _isSwipeContext(Offset position) {
    try {
      final hits = _elementsAtPosition(position);
      if (hits.isEmpty) return false;
      for (final element in _selfAndAncestors(hits.first)) {
        final w = element.widget;
        if (w is PageView || w is Dismissible || w is TabBarView) {
          return true;
        }
      }
    } catch (e) {
      _log('Error checking swipe context: $e');
    }
    return false;
  }

  /// Rapid repeated taps on one spot (4 within 30 px and 1 s), as in the
  /// browser SDK.
  final RageClickDetector _rageClicks = RageClickDetector();

  /// Records a tap in the shape the RUM heatmap reads for mobile apps (the
  /// native Android/iOS SDKs emit the same): `event.type=tap`, `screen.name`,
  /// logical-pixel coordinates with the viewport size (they line up with the
  /// replay frames), and a `target_xpath` unique per control, since the
  /// heatmap draws one point per distinct xpath.
  void _reportTap({
    required String targetElement,
    required String elementClasses,
    required String xpath,
    String? innerText,
    required double x,
    required double y,
    PointerDeviceKind? pointerKind,
    DateTime? downAt,
  }) {
    // Taken synchronously so rage-click timing reflects the real tap cadence.
    final route = _screenName();
    final rage =
        WebInstrumentation.rageClickEnabled && _rageClicks.isRageClick(x, y);
    Size? viewport;
    try {
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      viewport = view.physicalSize / view.devicePixelRatio;
    } catch (_) {}
    final label =
        innerText == null ? 'tap on $targetElement' : "tap on '$innerText'";
    unawaited(
      _report(() {
        final attrs = <String, Object>{
          'event.type': 'tap',
          'component': 'ui',
          'screen.name': route,
          'x': x,
          'y': y,
          'pageX': x,
          'pageY': y,
          if (viewport != null) 'viewport.width': viewport.width,
          if (viewport != null) 'viewport.height': viewport.height,
          'target_xpath':
              '/${route.startsWith('/') ? route.substring(1) : route}$xpath',
          'target_element': targetElement,
          'target.class': targetElement,
          if (innerText != null) 'target.text': innerText,
          'pointer.type': switch (pointerKind) {
            PointerDeviceKind.touch => 'touch',
            PointerDeviceKind.stylus ||
            PointerDeviceKind.invertedStylus => 'pen',
            _ => 'mouse',
          },
          if (rage) 'frustration.type': 'rage_click',
          // Kept for existing queries.
          'ui.auto.capture': true,
          'ui.auto.x': x,
          'ui.auto.y': y,
          'ui.auto.widget_class': elementClasses,
          if (innerText != null) 'ui.auto.target_text': innerText,
        };
        final span = FlutterOTel.tracer.recordUserInteraction(
          route,
          InteractionType.click,
          targetName: targetElement,
          attributes: attrs.toAttributes(),
          spanName: label,
        );
        WebInstrumentation.onInteraction(span, label, startedAt: downAt);
      }),
    );
  }

  /// The screen a tap belongs to: the route from `FlutterOTel.routeObserver`,
  /// or on the web the page path (hash routes included) when the app has no
  /// observer.
  static String _screenName() {
    final route = FlutterOTel.currentInteractionRouteName;
    if (route != 'unknown_route') return route;
    return WebInstrumentation.pagePath ?? route;
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
              {
                InteractionType.gestureDirection.key: direction.value,
              }.toAttributes(),
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
      // Debug builds can map the real hit-test path back to elements, which
      // respects IgnorePointer / hit-test behaviour. Release builds have no
      // RenderObject -> Element link, so a pruned geometric lookup is used.
      Element? deepest;
      if (kDebugMode) {
        final hitTestResult = HitTestResult();
        _hitTestAt(position, hitTestResult);
        for (final entry in hitTestResult.path) {
          final target = entry.target;
          if (target is RenderObject) {
            final creator = target.debugCreator;
            if (creator is DebugCreator) {
              deepest = creator.element;
              break;
            }
          }
        }
      }
      List<Element>? hits;
      if (deepest == null) {
        hits = _elementsAtPosition(position);
        if (hits.isNotEmpty) deepest = hits.first;
      }
      if (deepest == null) {
        return _WidgetInfo(targetElement: 'Screen', widgetClassName: 'Screen');
      }

      // One upward scan from the deepest element: the nearest specific
      // control wins; a bare GestureDetector/InkWell is the fallback.
      Element? bestInteractive;
      Element? genericFallback;
      for (final element in _selfAndAncestors(deepest)) {
        final widget = element.widget;
        if (!_isInteractive(widget)) continue;
        if (_isGenericGesture(widget)) {
          genericFallback ??= element;
        } else {
          bestInteractive = element;
          break;
        }
      }

      // A barrier Listener on top (dialogs) hides the control under it: pick
      // the smallest control at the point instead.
      if (bestInteractive == null && deepest.widget is Listener) {
        hits ??= _elementsAtPosition(position);
        bestInteractive = _smallestInteractive(hits);
      }
      bestInteractive ??= genericFallback;

      final elementClassName =
          bestInteractive == null ? null : _widgetName(bestInteractive.widget);

      String? textContent;
      String? semanticsLabel;
      if (bestInteractive != null) {
        textContent = _findTextInChildren(bestInteractive);
      }
      if (textContent == null) {
        for (final element in _selfAndAncestors(deepest)) {
          final widget = element.widget;
          if (widget is Text) {
            textContent = _nonEmpty(
              widget.data ?? widget.textSpan?.toPlainText(),
            );
          } else if (widget is RichText) {
            textContent = _nonEmpty(widget.text.toPlainText());
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
          if (textContent != null) break;
        }
      }

      final targetElement = elementClassName ?? 'Screen';
      return _WidgetInfo(
        targetElement: targetElement,
        text: textContent,
        accessibilityLabel: semanticsLabel,
        widgetClassName: targetElement,
        xpath:
            bestInteractive == null
                ? '/Screen'
                : _xpathOf(bestInteractive, targetElement),
      );
    } catch (e) {
      _log('Error extracting widget info: $e');
    }

    return _WidgetInfo(targetElement: 'Screen', widgetClassName: 'Screen');
  }

  /// [element] followed by its ancestors up to the root.
  static Iterable<Element> _selfAndAncestors(Element element) sync* {
    yield element;
    final ancestors = <Element>[];
    element.visitAncestorElements((ancestor) {
      ancestors.add(ancestor);
      return true;
    });
    yield* ancestors;
  }

  /// Name of a known control. Matched by type, not by `runtimeType.toString()`,
  /// which is minified in release web builds (`minified:uh`).
  static String? _knownWidgetName(Widget w) => switch (w) {
    ElevatedButton() => 'ElevatedButton',
    FilledButton() => 'FilledButton',
    OutlinedButton() => 'OutlinedButton',
    TextButton() => 'TextButton',
    ButtonStyleButton() => 'ButtonStyleButton',
    // Back/CloseButton are IconButtons: match them first.
    BackButton() => 'BackButton',
    CloseButton() => 'CloseButton',
    IconButton() => 'IconButton',
    FloatingActionButton() => 'FloatingActionButton',
    PopupMenuButton() => 'PopupMenuButton',
    DropdownButton() => 'DropdownButton',
    Card() => 'Card',
    ListTile() => 'ListTile',
    Tab() => 'Tab',
    Chip() ||
    ActionChip() ||
    ChoiceChip() ||
    FilterChip() ||
    InputChip() => 'Chip',
    Dismissible() => 'Dismissible',
    Switch() => 'Switch',
    Checkbox() => 'Checkbox',
    Radio() => 'Radio',
    Slider() => 'Slider',
    BottomNavigationBar() => 'BottomNavigationBar',
    NavigationBar() => 'NavigationBar',
    NavigationRail() => 'NavigationRail',
    TabBar() => 'TabBar',
    AlertDialog() => 'AlertDialog',
    SimpleDialog() => 'SimpleDialog',
    Dialog() => 'Dialog',
    InkWell() => 'InkWell',
    InkResponse() => 'InkResponse',
    GestureDetector() => 'GestureDetector',
    _ => null,
  };

  static bool _isInteractive(Widget w) => _knownWidgetName(w) != null;

  static bool _isGenericGesture(Widget w) =>
      w is InkResponse || w is GestureDetector;

  static String _widgetName(Widget w) {
    final known = _knownWidgetName(w);
    if (known != null) return known;
    final raw = w.runtimeType.toString();
    return raw.startsWith('_') ? raw.substring(1) : raw;
  }

  static const int _maxXPathSegments = 8;

  /// A path that tells controls on one screen apart: the control's position
  /// among its siblings at each point where the tree branches (single-child
  /// wrappers such as Padding add nothing and are skipped), nearest
  /// [_maxXPathSegments] levels, plus its string key when it has one.
  /// Segment names are real widget names only for known controls; others are
  /// `*`, because release builds minify class names and a name that changes
  /// every build would split the heatmap across versions.
  static String _xpathOf(Element target, String targetName) {
    final key = target.widget.key;
    final keySuffix =
        key is ValueKey<String>
            ? '#${key.value}'
            : (key is ValueKey<int> ? '#${key.value}' : '');
    final segments = <String>[];
    Element child = target;
    var first = true;
    for (final parent in _selfAndAncestors(target).skip(1)) {
      if (segments.length >= _maxXPathSegments) break;
      final siblings = <Element>[];
      parent.visitChildren(siblings.add);
      if (first || siblings.length > 1) {
        final name =
            first
                ? '$targetName$keySuffix'
                : (_knownWidgetName(child.widget) ?? '*');
        final index = siblings.indexWhere((e) => identical(e, child));
        segments.add('$name[${index < 0 ? 0 : index}]');
        first = false;
      }
      child = parent;
    }
    return '/${segments.reversed.join('/')}';
  }

  Element? _smallestInteractive(List<Element> hits) {
    Element? best;
    var bestArea = double.infinity;
    for (final element in hits) {
      final widget = element.widget;
      if (!_isInteractive(widget) || _isGenericGesture(widget)) continue;
      final ro = element.renderObject;
      if (ro is! RenderBox || !ro.hasSize) continue;
      final area = ro.size.width * ro.size.height;
      if (area < bestArea) {
        bestArea = area;
        best = element;
      }
    }
    return best;
  }

  /// Elements whose box contains [position], deepest (and topmost) first.
  ///
  /// Subtrees whose box doesn't contain the point are skipped, so the cost is
  /// the path to the point plus its siblings instead of the whole tree; the
  /// containment test runs once per render object, not once per element.
  List<Element> _elementsAtPosition(Offset position) {
    final hits = <Element>[];
    void visit(Element element, RenderObject? checked) {
      final ro = element.renderObject;
      if (ro is RenderBox && !identical(ro, checked)) {
        if (!ro.attached || !ro.hasSize) return;
        try {
          if (!(Offset.zero & ro.size).contains(ro.globalToLocal(position))) {
            return;
          }
        } catch (_) {
          return;
        }
      }
      if (ro is RenderBox) hits.add(element);
      element.visitChildren((child) => visit(child, ro));
    }

    WidgetsBinding.instance.rootElement?.visitChildren(
      (child) => visit(child, null),
    );
    return hits.reversed.toList(growable: false);
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
}

class _WidgetInfo {
  _WidgetInfo({
    required this.targetElement,
    this.text,
    this.accessibilityLabel,
    this.widgetClassName = 'Unknown',
    this.xpath = '/Screen',
  });

  final String targetElement;

  /// Widget path of the tapped control below the screen, e.g.
  /// `/Column[1]/Row[0]/IconButton[1]`.
  final String xpath;
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
  });

  final Offset startPosition;
  final Duration startTime;
  Offset lastPosition;
  Duration lastTime;
  bool hasMoved = false;

  /// Wall-clock time of the pointer down. Tap handlers run before this
  /// tracker sees the pointer up, so requests they fire are attributed from
  /// here.
  final DateTime downAt = DateTime.now();
}
