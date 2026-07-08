import 'package:flutter/material.dart';

/// Top-level destinations in the Pixa gallery.
///
/// Each value maps to a [GalleryTab] entry that the home shell renders.
/// Tests and integration drivers reference these enum values directly, so
/// they are the stable navigation contract.
enum GalleryTab {
  /// Live network feed with flex / masonry / grid layouts.
  gallery(Icons.photo_library_outlined, Icons.photo_library_rounded, 'Gallery'),

  /// Production recipes for every public Pixa capability.
  learn(Icons.menu_book_outlined, Icons.menu_book_rounded, 'Learn'),

  /// Runtime / cache / scheduler diagnostics and operations.
  diagnostics(
    Icons.monitor_heart_outlined,
    Icons.monitor_heart_rounded,
    'Runtime',
  ),

  /// Centralized app preferences: theme, defaults, cache.
  settings(Icons.settings_outlined, Icons.settings_rounded, 'Settings');

  const GalleryTab(this.icon, this.selectedIcon, this.label);

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}
