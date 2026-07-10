/// Largest value that can cross every supported native `uintptr_t` ABI.
const int pixaPortableUintPtrMax = 0xffffffff;

/// Validates a value before it crosses a `size_t`/`uintptr_t` FFI boundary.
void validatePixaPortableUintPtr(
  int value,
  String name, {
  bool allowZero = true,
}) {
  final int minimum = allowZero ? 0 : 1;
  if (value < minimum || value > pixaPortableUintPtrMax) {
    throw RangeError.range(value, minimum, pixaPortableUintPtrMax, name);
  }
}

/// Validates an optional TTL before encoding it as the runtime signed sentinel.
void validatePixaOptionalTtl(Duration? ttl, String name) {
  if (ttl?.isNegative ?? false) {
    throw ArgumentError.value(ttl, name, 'must not be negative');
  }
}

/// Validates the public HTTP/runtime concurrency contract.
void validatePixaNetworkConcurrency(int value, String name) {
  validatePixaPortableUintPtr(value, name, allowZero: false);
}
