import 'package:flutter/material.dart';

import '../../api/api_error.dart';
import '../../ui/inline_error.dart';

/// Loads data once, then shows [builder] with the result and a `reload` callback.
/// While loading it shows a spinner; a failed load shows the error text and a retry
/// button. A reload keeps the old data on screen until the new data is there.
class AsyncBody<T> extends StatefulWidget {
  const AsyncBody({
    super.key,
    required this.load,
    required this.builder,
    this.fullScreen = false,
  });

  /// Wrap the loading and error states in a Scaffold (for screens with no app bar
  /// of their own while loading).
  final bool fullScreen;

  final Future<T> Function() load;
  final Widget Function(
    BuildContext context,
    T data,
    Future<void> Function() reload,
  )
  builder;

  @override
  State<AsyncBody<T>> createState() => _AsyncBodyState<T>();
}

class _AsyncBodyState<T> extends State<AsyncBody<T>> {
  T? _data;
  bool _loaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final data = await widget.load();
      if (!mounted) return;
      setState(() {
        _data = data;
        _loaded = true;
        _error = null;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loaded) return widget.builder(context, _data as T, _reload);
    Widget frame(Widget child) =>
        widget.fullScreen ? Scaffold(body: SafeArea(child: child)) : child;
    if (_error != null) {
      return frame(
        Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                InlineError(_error!),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () {
                    setState(() => _error = null);
                    _reload();
                  },
                  child: const Text('Coba lagi'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return frame(const Center(child: CircularProgressIndicator()));
  }
}

/// A filled button that shows a spinner while [busy].
class BusyButtonChild extends StatelessWidget {
  const BusyButtonChild({super.key, required this.busy, required this.label});

  final bool busy;
  final String label;

  @override
  Widget build(BuildContext context) => busy
      ? const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        )
      : Text(label);
}
