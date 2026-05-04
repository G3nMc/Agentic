import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// A thin, invisible resize handle that can be dragged to adjust the height
/// of a panel below it. Shows a resize cursor on hover and provides visual
/// feedback when dragging.
class ResizeHandle extends StatefulWidget {
  /// Current height of the panel being resized.
  final double height;

  /// Called when the user drags the handle to change the height.
  final ValueChanged<double> onHeightChanged;

  /// Minimum allowed height for the panel.
  final double minHeight;

  /// Maximum allowed height for the panel.
  final double maxHeight;

  const ResizeHandle({
    super.key,
    required this.height,
    required this.onHeightChanged,
    this.minHeight = 40.0,
    this.maxHeight = 600.0,
  });

  @override
  State<ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<ResizeHandle> {
  bool _isHovering = false;
  bool _isDragging = false;
  double? _startY;
  double? _startHeight;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) {
        setState(() => _isHovering = false);
        _isDragging = false;
        _startY = null;
        _startHeight = null;
      },
      child: GestureDetector(
        onPanStart: (details) {
          setState(() {
            _isDragging = true;
            _startY = details.globalPosition.dy;
            _startHeight = widget.height;
          });
        },
        onPanEnd: (_) {
          setState(() {
            _isDragging = false;
            _startY = null;
            _startHeight = null;
          });
        },
        onPanUpdate: (details) {
          if (_startY == null || _startHeight == null) return;
          final deltaY = _startY! - details.globalPosition.dy;
          final newHeight = _startHeight! + deltaY;
          final clampedHeight = newHeight.clamp(widget.minHeight, widget.maxHeight);
          if (clampedHeight != widget.height) {
            widget.onHeightChanged(clampedHeight);
          }
        },
        child: Container(
          height: 8,
          margin: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: _isHovering || _isDragging
                ? AppTheme.accent.withAlpha(40)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Center(
            child: Container(
              width: 40,
              height: 3,
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
