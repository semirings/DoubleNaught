import 'package:flutter/foundation.dart';

/// Which SAM3 interaction the user is currently performing.
enum Sam3Mode { text, box, point }

/// A box prompt in normalized (0..1) image coordinates, so it is
/// resolution-independent.
@immutable
class Sam3Box {
  final double left;
  final double top;
  final double right;
  final double bottom;
  final bool include;

  const Sam3Box({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.include,
  });
}

/// A point prompt in normalized (0..1) image coordinates.
@immutable
class Sam3Point {
  final double x;
  final double y;
  final bool include;

  const Sam3Point({required this.x, required this.y, required this.include});
}

/// Shared SAM3 prompt-interaction state, the single source of truth linking the
/// Segmentation node's control panel (mode + Include/Exclude toggles) to the
/// image panel (where boxes and points are actually drawn). Both listen to and
/// mutate this one model so they never drift out of sync.
class Sam3InteractionModel extends ChangeNotifier {
  Sam3Mode _mode = Sam3Mode.text;
  bool _boxInclude = true;
  bool _pointInclude = true;

  /// Drawn prompts, in normalized coordinates.
  final List<Sam3Box> boxes = [];
  final List<Sam3Point> points = [];

  Sam3Mode get mode => _mode;
  bool get boxInclude => _boxInclude;
  bool get pointInclude => _pointInclude;

  void setMode(Sam3Mode m) {
    if (_mode != m) {
      _mode = m;
      notifyListeners();
    }
  }

  void setBoxInclude(bool v) {
    if (_boxInclude != v) {
      _boxInclude = v;
      notifyListeners();
    }
  }

  void setPointInclude(bool v) {
    if (_pointInclude != v) {
      _pointInclude = v;
      notifyListeners();
    }
  }

  void addBox(Sam3Box b) {
    boxes.add(b);
    notifyListeners();
  }

  void removeBox(Sam3Box b) {
    boxes.remove(b);
    notifyListeners();
  }

  void addPoint(Sam3Point p) {
    points.add(p);
    notifyListeners();
  }

  void removePoint(Sam3Point p) {
    points.remove(p);
    notifyListeners();
  }
}
