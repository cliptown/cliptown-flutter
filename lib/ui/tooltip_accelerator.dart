import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Hover delay for tooltips when no modifier is held.
const Duration defaultTooltipWait = Duration(milliseconds: 700);

/// Shows tooltips instantly while Option (macOS) / Alt is held.
///
/// Normally tooltips wait [defaultTooltipWait] so they do not flicker while
/// the pointer crosses the UI. Holding Option/Alt switches every tooltip below
/// this widget to zero delay — hold it and sweep the pointer to read what each
/// control does. Key events are observed, never consumed, so Option/Alt
/// shortcuts keep working.
class TooltipAccelerator extends StatefulWidget {
  const TooltipAccelerator({super.key, required this.child, this.keyboard});

  final Widget child;

  /// Injected in tests; defaults to [HardwareKeyboard.instance].
  final HardwareKeyboard? keyboard;

  @override
  State<TooltipAccelerator> createState() => _TooltipAcceleratorState();
}

class _TooltipAcceleratorState extends State<TooltipAccelerator> {
  late final HardwareKeyboard _keyboard =
      widget.keyboard ?? HardwareKeyboard.instance;
  bool _accelerated = false;

  @override
  void initState() {
    super.initState();
    _accelerated = _keyboard.isAltPressed;
    _keyboard.addHandler(_onKey);
  }

  @override
  void dispose() {
    _keyboard.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    final accelerated = _keyboard.isAltPressed;
    if (accelerated != _accelerated && mounted) {
      setState(() => _accelerated = accelerated);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final base = TooltipTheme.of(context);
    return TooltipTheme(
      data: base.copyWith(
        waitDuration: _accelerated ? Duration.zero : defaultTooltipWait,
      ),
      child: widget.child,
    );
  }
}
