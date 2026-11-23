// A channel logo or poster from the core's disk cache (gerdtv_core::logos): downloaded once, then read from disk.
// Until the file is there (or when the URL fails) the kind's icon shows, so rows never jump; the picture then fades
// in (Tokens.motion; at once with reduced motion, or when the file was decoded before).
// [fill]: posters fill their whole box, edge to edge (cropped, BoxFit.cover); logos sit whole inside a square.

import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../src/rust/api/logos.dart';
import '../theme.dart';

class Logo extends StatelessWidget {
  const Logo({
    super.key,
    required this.url,
    required this.size,
    required this.icon,
    this.fill = false,
  });
  final String url;

  /// The square's side; with [fill], the width the picture is decoded at (the box itself comes from the parent).
  final double size;
  final IconData icon;
  final bool fill;

  /// One lookup per URL per run: rebuilding a row never asks the core again.
  static final Map<String, Future<String?>> _files = {};

  @override
  Widget build(BuildContext context) {
    final fallback = Icon(icon, size: (fill ? 48.0 : size) * 0.6);
    Widget box(Widget child) => fill
        ? SizedBox.expand(child: child)
        : SizedBox.square(dimension: size, child: child);
    if (!url.startsWith('http')) return box(Center(child: fallback));
    final still = MediaQuery.disableAnimationsOf(context);
    return box(
      FutureBuilder<String?>(
        future: _files.putIfAbsent(url, () => logoFile(url: url)),
        builder: (context, snap) {
          final path = snap.data;
          if (path == null) return Center(child: fallback);
          return Image.file(
            File(path),
            fit: fill ? BoxFit.cover : BoxFit.contain,
            // Decoded at display size, not the file's (some providers ship 1000 px logos).
            cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
            errorBuilder: (_, _, _) => Center(child: fallback),
            frameBuilder: (context, child, frame, sync) => sync || still
                ? child
                : AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: Tokens.motion,
                    child: child,
                  ),
          );
        },
      ),
    );
  }
}
