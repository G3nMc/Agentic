import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// A thin, invisible vertical resize handle that can be dragged to adjust the
/// width of the panel to its left. Shows a resize cursor on hover and provides
/// visual feedback when dragging.
class HorizontalResizeHandle extends StatefulWidget {
  /// Current width of the panel being resized.
  final double width;

  /// Called when the user drags the handle to change the width.
  final ValueChanged<double> onWidthChanged;

  /// Minimum allowed width for the panel.
  final double minWidth;

  /// Maximum allowed width for the panel.
  final double maxWidth;

  const HorizontalResizeHandle({
    super.key,
    required this.width,
    required this.onWidthChanged,
    this.minWidth = 120.0,
    this.maxWidth = 600.0,
  });

  @override
  State<HorizontalResizeHandle> createState() => _HorizontalResizeHandleState();
}

class _HorizontalResizeHandleState extends State<HorizontalResizeHandle> {
  bool _isHovering = false;
  bool _isDragging = false;
  double? _startX;
  double? _startWidth;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: GestureDetector(
        onPanStart: (details) {
          setState(() {
            _isDragging = true;
            _startX = details.globalPosition.dx;
            _startWidth = widget.width;
          });
        },
        onPanEnd: (_) {
          setState(() {
            _isDragging = false;
            _startX = null;
            _startWidth = null;
          });
        },
        onPanUpdate: (details) {
          if (_startX == null || _startWidth == null) return;
          final deltaX = details.globalPosition.dx - _startX!;
          final newWidth = _startWidth! + deltaX;
          final clampedWidth = newWidth.clamp(widget.minWidth, widget.maxWidth);
          if (clampedWidth != widget.width) {
            widget.onWidthChanged(clampedWidth);
          }
        },
        child: Container(
          width: 8,
          margin: const EdgeInsets.symmetric(vertical: 40),
          decoration: BoxDecoration(
            color: _isHovering || _isDragging
                ? AppTheme.accent.withAlpha(40)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Center(
            child: Container(
              width: 3,
              height: 40,
              decoration: BoxDecoration(
                color: _isHovering || _isDragging
                    ? AppTheme.accent
                    : AppTheme.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}