import 'package:flutter/material.dart';

/// Dropdown picker for token-count fields (`num_ctx`, `num_predict` /
/// `max_tokens`) with K-suffixed presets and a "Custom" escape hatch for
/// arbitrary values. Wraps a [TextEditingController] so it drops in wherever
/// a numeric `TextField` was already used: the controller still holds the
/// canonical string value, parent code reads/writes it the same way as
/// before, and [onChanged] fires with the same string payload a
/// `TextField.onChanged` would give.
class TokenCountPicker extends StatefulWidget {
  const TokenCountPicker({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.presets,
    this.labelText,
    this.helperText,
    this.hintText,
    this.outlined = false,
    this.isDense = false,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  /// The values offered as preset options. Anything outside this list ends up
  /// in the "Custom" branch.
  final List<int> presets;

  final String? labelText;
  final String? helperText;
  final String? hintText;

  /// Use [OutlineInputBorder] (matches the per-role agent settings card).
  final bool outlined;
  final bool isDense;

  /// Sensible presets for `num_ctx` — total context window. Cloud models
  /// typically support 128K+; local Ollama defaults to 4K-8K. The 2K floor
  /// covers tiny chit-chat models, the 512K ceiling matches frontier cloud
  /// models like Claude/Gemini at long-context settings.
  static const List<int> numCtxPresets = [
    2048,
    4096,
    8192,
    16384,
    32768,
    65536,
    131072,
    262144,
    524288,
  ];

  /// Sensible presets for `num_predict` / `max_tokens` — reply-length cap
  /// only. 256-2K covers short chat replies; 4K-16K is a typical
  /// whole-file rewrite budget; 32K-64K matches the maximum output most
  /// frontier cloud models will emit in a single call.
  static const List<int> maxTokensPresets = [
    256,
    512,
    1024,
    2048,
    4096,
    8192,
    16384,
    32768,
    65536,
  ];

  static String formatK(int tokens) {
    if (tokens < 1024) return '$tokens';
    if (tokens % 1024 == 0) return '${tokens ~/ 1024}K';
    return '${(tokens / 1024).toStringAsFixed(1)}K';
  }

  @override
  State<TokenCountPicker> createState() => _TokenCountPickerState();
}

class _TokenCountPickerState extends State<TokenCountPicker> {
  /// Sentinel for the "Custom" dropdown entry (negative so it can never
  /// collide with a real token count).
  static const int _customSentinel = -1;

  late int _selected;

  @override
  void initState() {
    super.initState();
    _selected = _resolveFromController();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  int _resolveFromController() {
    final parsed = int.tryParse(widget.controller.text.trim());
    if (parsed != null && widget.presets.contains(parsed)) return parsed;
    return _customSentinel;
  }

  void _onControllerChanged() {
    final next = _resolveFromController();
    if (next != _selected) {
      setState(() => _selected = next);
    }
  }

  void _onDropdownChanged(int? value) {
    if (value == null) return;
    setState(() => _selected = value);
    if (value == _customSentinel) {
      // Keep whatever the user already typed; just reveal the input.
      return;
    }
    final asText = value.toString();
    if (widget.controller.text != asText) {
      widget.controller.text = asText;
    }
    widget.onChanged(asText);
  }

  void _onCustomChanged(String v) {
    widget.onChanged(v);
  }

  InputDecoration _decoration({String? label, String? helper, String? hint}) {
    return InputDecoration(
      labelText: label,
      helperText: helper,
      hintText: hint,
      border: widget.outlined ? const OutlineInputBorder() : null,
      isDense: widget.isDense,
    );
  }

  String _itemLabel(int preset) {
    if (preset < 1024) return '$preset tokens';
    return '${TokenCountPicker.formatK(preset)}  ·  $preset tokens';
  }

  @override
  Widget build(BuildContext context) {
    final isCustom = _selected == _customSentinel;
    final items = <DropdownMenuItem<int>>[
      for (final preset in widget.presets)
        DropdownMenuItem<int>(
          value: preset,
          child: Text(_itemLabel(preset)),
        ),
      const DropdownMenuItem<int>(
        value: _customSentinel,
        child: Text('Custom…'),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InputDecorator(
          decoration: _decoration(
            label: widget.labelText,
            helper: isCustom ? null : widget.helperText,
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: _selected,
              isExpanded: true,
              items: items,
              onChanged: _onDropdownChanged,
            ),
          ),
        ),
        if (isCustom) ...[
          const SizedBox(height: 8),
          TextField(
            controller: widget.controller,
            keyboardType: TextInputType.number,
            decoration: _decoration(
              label: 'Custom value',
              helper: widget.helperText,
              hint: widget.hintText ?? 'e.g. 40960',
            ),
            onChanged: _onCustomChanged,
          ),
        ],
      ],
    );
  }
}
