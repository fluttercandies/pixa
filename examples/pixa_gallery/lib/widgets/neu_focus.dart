import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/neu_palette.dart';

/// A neumorphic focus affordance for keyboard users.
///
/// Wraps an interactive control so that:
/// - it participates in the tab/Focus-traversal order,
/// - it shows a soft accent-coloured outline when focused (the "focus ring"),
/// - Enter / Space activate [onActivate].
///
/// This is the single place the gallery adds keyboard reachability + a
/// visible focus state, so the whole neumorphic control set stays consistent.
class NeuFocusable extends StatefulWidget {
  const NeuFocusable({
    super.key,
    required this.child,
    this.onActivate,
    this.borderRadius,
    this.enabled = true,
    this.autofocus = false,
  });

  final Widget child;
  final VoidCallback? onActivate;
  final BorderRadius? borderRadius;
  final bool enabled;
  final bool autofocus;

  @override
  State<NeuFocusable> createState() => _NeuFocusableState();
}

class _NeuFocusableState extends State<NeuFocusable> {
  late final FocusNode _node;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node = FocusNode(onKeyEvent: _onKeyEvent);
    _node.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _node.removeListener(_onFocusChange);
    _node.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    final bool f = _node.hasFocus;
    if (f != _focused) {
      setState(() => _focused = f);
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!widget.enabled || widget.onActivate == null) {
      return KeyEventResult.ignored;
    }
    final isActivate =
        event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space);
    if (isActivate) {
      widget.onActivate!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return Focus(
      focusNode: _node,
      canRequestFocus: widget.enabled,
      child: _focused
          ? Stack(
              children: <Widget>[
                widget.child,
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius:
                            widget.borderRadius ?? BorderRadius.circular(16),
                        border: Border.all(
                          color: palette.accent.withValues(alpha: 0.85),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            )
          : widget.child,
    );
  }
}
