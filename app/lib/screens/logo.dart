// A channel logo or poster from the core's disk cache (gerdtv_core::logos): downloaded once, then read from disk.
// Until the file is there (or when the URL fails) the kind's icon shows, so rows never jump.

import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../src/rust/api/logos.dart';

class Logo extends StatelessWidget {
  const Logo({
    super.key,
    required this.url,
    required this.size,
    required this.icon,
  });
  final String url;
  final double size;
  final IconData icon;

  /// One lookup per URL per run: rebuilding a row never asks the core again.
  static final Map<String, Future<String?>> _files = {};

  @override
  Widget build(BuildContext context) {
    final fallback = Icon(icon, size: size * 0.6);
    if (!url.startsWith('http')) {
      return SizedBox.square(
        dimension: size,
        child: Center(child: fallback),
      );
    }
    return SizedBox.square(
      dimension: size,
      child: FutureBuilder<String?>(
        future: _files.putIfAbsent(url, () => logoFile(url: url)),
        builder: (context, snap) {
          final path = snap.data;
          if (path == null) return Center(child: fallback);
          return Image.file(
            File(path),
            fit: BoxFit.contain,
            // Decoded at display size, not the file's (some providers ship 1000 px logos).
            cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
            errorBuilder: (_, _, _) => Center(child: fallback),
          );
        },
      ),
    );
  }
}
