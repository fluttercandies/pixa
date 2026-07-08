import 'package:flutter/material.dart';

import '../models/image_post.dart';

/// A group of [LearnScenario]s shown under one heading on the Learn page.
class LearnGroup {
  const LearnGroup({required this.title, required this.scenarios});
  final String title;
  final List<LearnScenario> scenarios;
}

/// A single capability recipe on the Learn page.
class LearnScenario {
  const LearnScenario({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.builder,
    this.apiNote = '',
  });

  final String title;

  /// One-line description of the user-facing capability.
  final String subtitle;

  /// One-line note naming the public API this recipe demonstrates, e.g.
  /// "API: PixaImage.network / PixaRetryPolicy". Surfaced under the preview
  /// so users can map a visible behaviour back to the library surface.
  final String apiNote;

  final IconData icon;
  final WidgetBuilder builder;
}

/// Picks a real image post to drive the Learn previews, falling back to a
/// curated public image when no feed is loaded.
ImagePost learnImagePost(List<ImagePost> feed, {int index = 0}) {
  if (feed.isNotEmpty) {
    return feed[index % feed.length];
  }
  return const ImagePost(
    id: 1001,
    imageUrl: 'https://www.gstatic.com/webp/gallery/1.jpg',
    width: 550,
    height: 368,
    source: SourceType.nekosia,
  );
}
