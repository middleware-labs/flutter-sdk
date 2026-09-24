// Licensed under the Apache License, Version 2.0

/// An rrweb event: `{type, timestamp, data}`.
class RRWebEvent {
  final int type;
  final int timestamp;
  final Map<String, Object?> data;

  const RRWebEvent(this.type, this.timestamp, this.data);
}

/// Factory for the rrweb events emitted by the Dart session recorder. Same
/// shape as the native SDKs' v3 recorders, so the Middleware rrweb player
/// replays all of them the same way.
///
/// The recording is screenshot-based: the replayed "DOM" is a fixed six-node
/// document whose only visible element is a full-viewport `<img>`; every new
/// frame is an attribute mutation swapping that image's `src`. The node ids are
/// constant — rrweb rebuilds its mirror on each FullSnapshot, so reusing them
/// across snapshots is safe.
///
/// All coordinates and sizes are logical px, all timestamps epoch ms.
class RRWebEvents {
  RRWebEvents._();

  // rrweb event types
  static const int typeFullSnapshot = 2;
  static const int typeIncrementalSnapshot = 3;
  static const int typeMeta = 4;
  static const int typeCustom = 5;

  // rrweb incremental sources
  static const int sourceMutation = 0;
  static const int sourceMouseInteraction = 2;

  // rrweb mouse interaction types
  static const int mouseInteractionTouchStart = 7;
  static const int mouseInteractionTouchEnd = 9;

  // rrweb serialized node types
  static const int _nodeDocument = 0;
  static const int _nodeDocumentType = 1;
  static const int _nodeElement = 2;

  // Fixed node ids of the synthetic document
  static const int _nodeIdDocument = 1;
  static const int _nodeIdDoctype = 2;
  static const int _nodeIdHtml = 3;
  static const int _nodeIdHead = 4;
  static const int _nodeIdBody = 5;
  static const int nodeIdScreen = 6;

  static const int _pointerTypeTouch = 2;

  static RRWebEvent meta(String href, int width, int height, int timestamp) =>
      RRWebEvent(typeMeta, timestamp, {
        'href': href,
        'width': width,
        'height': height,
      });

  static RRWebEvent fullSnapshot(
    String frameDataUri,
    int width,
    int height,
    int timestamp,
  ) {
    final img = _element(nodeIdScreen, 'img', {
      'id': 'mw-screen',
      'src': frameDataUri,
      'style': 'width:${width}px;height:${height}px;display:block;',
    });
    final head = _element(_nodeIdHead, 'head', {});
    final body = _element(
      _nodeIdBody,
      'body',
      {'style': 'margin:0;padding:0;background:#000;overflow:hidden;'},
      [img],
    );
    final html = _element(_nodeIdHtml, 'html', {}, [head, body]);
    final doctype = <String, Object?>{
      'type': _nodeDocumentType,
      'id': _nodeIdDoctype,
      'name': 'html',
      'publicId': '',
      'systemId': '',
    };
    return RRWebEvent(typeFullSnapshot, timestamp, {
      'node': {
        'type': _nodeDocument,
        'id': _nodeIdDocument,
        'childNodes': [doctype, html],
      },
      'initialOffset': {'left': 0, 'top': 0},
    });
  }

  static RRWebEvent frameMutation(String frameDataUri, int timestamp) =>
      RRWebEvent(typeIncrementalSnapshot, timestamp, {
        'source': sourceMutation,
        'texts': const <Object>[],
        'removes': const <Object>[],
        'adds': const <Object>[],
        'attributes': [
          {
            'id': nodeIdScreen,
            'attributes': {'src': frameDataUri},
          },
        ],
      });

  static RRWebEvent touch(int interactionType, int x, int y, int timestamp) =>
      RRWebEvent(typeIncrementalSnapshot, timestamp, {
        'source': sourceMouseInteraction,
        'type': interactionType,
        'id': nodeIdScreen,
        'x': x,
        'y': y,
        'pointerType': _pointerTypeTouch,
      });

  static RRWebEvent screenCustom(String screenName, int timestamp) =>
      RRWebEvent(typeCustom, timestamp, {
        'tag': 'screen',
        'payload': {'name': screenName},
      });

  static Map<String, Object?> _element(
    int id,
    String tagName,
    Map<String, Object?> attributes, [
    List<Object?> childNodes = const [],
  ]) => {
    'type': _nodeElement,
    'id': id,
    'tagName': tagName,
    'attributes': attributes,
    'childNodes': childNodes,
  };
}
