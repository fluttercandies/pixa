import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Returns the 2D scene scale from a Flutter transform matrix.
double pixaLargeImageTransformScale(Matrix4 transform) {
  final storage = transform.storage;
  final double scaleX = math.sqrt(
    storage[0] * storage[0] + storage[1] * storage[1],
  );
  final double scaleY = math.sqrt(
    storage[4] * storage[4] + storage[5] * storage[5],
  );
  return math.max(scaleX, scaleY);
}
