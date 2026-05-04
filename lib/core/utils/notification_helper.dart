import 'package:flutter/material.dart';

/// Centralized notification helper for consistent notifications across the app.
///
/// All notifications appear at bottom-left with:
/// - Width matching sidebar (~280px)
/// - Semi-transparent dark background
/// - White readable text
/// - Extra height for multi-line content
/// - Consistent sizing and positioning
///
/// Usage: NotificationHelper.showSuccess(context, 'Message');
class NotificationHelper {
  NotificationHelper._();

  /// Sidebar width for notifications
  static const double _notificationWidth = 282.0;

  /// Shows a success notification (green)
  static void showSuccess(BuildContext context, String message) {
    _show(context, message, const Color(0x4D5A965A));
  }

  /// Shows an error notification (red)
  static void showError(BuildContext context, String message) {
    _show(context, message, const Color(0x66CF6679));
  }

  /// Shows an info notification (blue)
  static void showInfo(BuildContext context, String message) {
    _show(context, message, const Color(0x662196F3));
  }

  /// Shows a warning notification (orange)
  static void showWarning(BuildContext context, String message) {
    _show(context, message, const Color(0x66FF9800));
  }

  /// Generic show method with custom color
  static void show(
    BuildContext context,
    String message, {
    Color? backgroundColor,
    Duration duration = const Duration(seconds: 3),
  }) {
    _show(context, message, backgroundColor, duration: duration);
  }

  static void _show(
    BuildContext context,
    String message,
    Color? backgroundColor, {
    Duration duration = const Duration(seconds: 3),
  }) {
    // Remove any existing notification overlay
    _removeExistingOverlay();

    final overlay = Overlay.of(context);
    final overlayEntry = OverlayEntry(
      builder: (context) {
        // Wrap in Material so Text inherits DefaultTextStyle with
        // decoration: TextDecoration.none (otherwise text appears underlined).
        return Material(
          color: Colors.transparent,
          child: Stack(
            children: [
              Positioned(
                left: 8,
                bottom: 8,
                child: SizedBox(
                  width: _notificationWidth,
                  child: Container(
                    constraints: const BoxConstraints(
                      maxWidth: _notificationWidth,
                      minWidth: _notificationWidth,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                    decoration: BoxDecoration(
                      color: (backgroundColor ?? const Color(0xFF2C2C2C)).withAlpha(200),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(70),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Text(
                      message,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.left,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );

    // Store the overlay entry for cleanup
    _currentOverlayEntry = overlayEntry;
    overlay.insert(overlayEntry);

    // Auto-remove after duration
    Future.delayed(duration, () {
      _removeExistingOverlay();
    });
  }

  static OverlayEntry? _currentOverlayEntry;

  static void _removeExistingOverlay() {
    if (_currentOverlayEntry != null) {
      _currentOverlayEntry!.remove();
      _currentOverlayEntry = null;
    }
  }
}
