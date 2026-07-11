import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa_debug.dart';

void main() {
  test('pixa_debug exposes the registry architecture snapshot standalone', () {
    const Type snapshotType = PixaRegistryArchitectureSnapshot;
    final Object constructor = PixaRegistryArchitectureSnapshot.new;

    expect(snapshotType, PixaRegistryArchitectureSnapshot);
    expect(constructor, isNotNull);
  });
}
