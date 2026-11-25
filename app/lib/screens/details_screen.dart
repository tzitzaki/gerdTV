// A movie's page and a series' header (owner request: "feel like a popular streaming service"): the panel's
// backdrop (or the poster, blurred), after a moment the trailer muted in its place, then the title, a line of facts
// (year, length, rating, genre), Play and Trailer, the plot and the people. The details come from the panel when the
// page opens (Library.details, Xtream's get_vod_info / get_series_info) and may be partly or wholly empty: M3U
// sources have none, and the page then shows the title and Play only. Continue watching plays a movie directly.

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';
import 'item_tile.dart' show WatchedButton;
import 'list_modes.dart' show kindIcon;
import 'logo.dart';
import 'trailer.dart';

/// How long the backdrop shows before the muted trailer takes its place.
const trailerPreviewDelay = Duration(seconds: 2);

/// "2019 · 1 h 52 min · ★ 7.4 · Drama, Crime": what the panel knows, in that order.
String detailsFacts(ItemDetails d) {
  final year = RegExp(r'\d{4}').firstMatch(d.release)?.group(0);
  final secs = d.durationSecs ?? 0;
  final length = secs < 60
      ? null
      : secs >= 3600
      ? '${secs ~/ 3600} h ${secs % 3600 ~/ 60} min'
      : '${secs ~/ 60} min';
  final rating = d.rating == null ? null : '★ ${d.rating!.toStringAsFixed(1)}';
  return [
    ?year,
    ?length,
    ?rating,
    if (d.genre.trim().isNotEmpty) d.genre.trim(),
  ].join(' · ');
}

/// The page's top: the backdrop, and the muted trailer over it once [trailerPreviewDelay] passed (where the app
/// plays trailers, the trailer exists, motion isn't reduced and [active]: not while another page covers this one).
class DetailsBackdrop extends StatefulWidget {
  const DetailsBackdrop({
    super.key,
    required this.item,
    required this.details,
    required this.active,
    required this.fallback,
  });
  final ItemInfo item;
  final ItemDetails? details;
  final bool active;

  /// Shown when the panel has no backdrop (the series page's blurred poster).
  final Widget fallback;

  @override
  State<DetailsBackdrop> createState() => _DetailsBackdropState();
}

class _DetailsBackdropState extends State<DetailsBackdrop> {
  Timer? _timer;
  bool _preview = false;
  bool _refused = false;

  @override
  void didUpdateWidget(DetailsBackdrop old) {
    super.didUpdateWidget(old);
    _schedule();
  }

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  void _schedule() {
    final trailer = widget.details?.trailer ?? '';
    if (!widget.active || trailer.isEmpty || _refused || !trailersInApp) {
      _timer?.cancel();
      _timer = null;
      if (_preview) setState(() => _preview = false);
      return;
    }
    _timer ??= Timer(trailerPreviewDelay, () {
      if (mounted) setState(() => _preview = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final backdrop = widget.details?.backdrop ?? '';
    final surface = Theme.of(context).colorScheme.surface;
    final still = MediaQuery.disableAnimationsOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (backdrop.startsWith('http'))
          Logo(
            url: backdrop,
            size: 1280,
            icon: kindIcon(widget.item.kind),
            fill: true,
          )
        else
          widget.fallback,
        if (_preview && !still)
          // Muted and without controls: a picture, so it takes no taps (the Trailer button plays it properly).
          IgnorePointer(
            child: TrailerView(
              key: const Key('details.preview'),
              id: widget.details!.trailer,
              muted: true,
              onError: (_) => setState(() {
                _refused = true;
                _preview = false;
              }),
            ),
          ),
        // The page's colour rises from the bottom, so the title below reads on any picture.
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.center,
                end: Alignment.bottomCenter,
                colors: [surface.withValues(alpha: 0), surface],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Title, facts, the buttons ([onPlay] null: none, as on a series, whose episodes play), plot and people.
class DetailsInfo extends StatelessWidget {
  const DetailsInfo({
    super.key,
    required this.item,
    required this.details,
    this.onPlay,
    this.watched = false,
    this.onWatched,
  });
  final ItemInfo item;
  final ItemDetails? details;
  final VoidCallback? onPlay;

  /// A movie's watched check mark (null: none, as on a series).
  final bool watched;
  final VoidCallback? onWatched;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final d = details;
    final facts = d == null ? '' : detailsFacts(d);
    final trailer = d?.trailer ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Tokens.space * 2,
        0,
        Tokens.space * 2,
        Tokens.space * 2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.name, style: text.headlineSmall),
          if (facts.isNotEmpty) ...[
            const SizedBox(height: Tokens.space / 2),
            Text(facts, style: text.bodyMedium),
          ],
          const SizedBox(height: Tokens.space * 1.5),
          Wrap(
            spacing: Tokens.space,
            runSpacing: Tokens.space,
            children: [
              if (onPlay != null)
                FilledButton.icon(
                  key: const Key('details.play'),
                  autofocus: true, // TV: OK plays at once
                  icon: const Icon(Icons.play_arrow),
                  label: Text(l10n.detailsPlay),
                  onPressed: onPlay,
                ),
              if (trailer.isNotEmpty)
                OutlinedButton.icon(
                  key: const Key('details.trailer'),
                  icon: const Icon(Icons.movie_outlined),
                  label: Text(l10n.trailer),
                  onPressed: () => playTrailer(context, trailer),
                ),
              if (onWatched != null)
                WatchedButton(
                  item: item,
                  watched: watched,
                  onPressed: onWatched!,
                ),
            ],
          ),
          if (d != null && d.plot.trim().isNotEmpty) ...[
            const SizedBox(height: Tokens.space * 1.5),
            Text(d.plot.trim(), style: text.bodyLarge),
          ],
          for (final people in [d?.director ?? '', d?.cast ?? ''])
            if (people.trim().isNotEmpty) ...[
              const SizedBox(height: Tokens.space),
              Text(
                people.trim(),
                style: text.bodySmall,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
        ],
      ),
    );
  }
}

/// A movie's page: backdrop (with the muted trailer), details, Play.
class MovieScreen extends StatefulWidget {
  const MovieScreen({
    super.key,
    required this.library,
    required this.movie,
    required this.onPlay,
    this.isWatched,
    this.onWatched,
  });
  final Library library;
  final ItemInfo movie;

  /// Opens the player (the caller's route, so the player keeps its usual way in).
  final Future<void> Function() onPlay;

  /// The watched check mark (null: none): read when drawn, toggled by [onWatched].
  final bool Function()? isWatched;
  final VoidCallback? onWatched;

  @override
  State<MovieScreen> createState() => _MovieScreenState();
}

class _MovieScreenState extends State<MovieScreen> {
  late final Future<ItemDetails?> _details = widget.library
      .details(key: widget.movie.key)
      .then<ItemDetails?>((d) => d)
      .catchError((Object _) => null); // no details: title and Play still work
  @override
  Widget build(BuildContext context) {
    // The preview runs only while this page is on top, not under the player; ModalRoute.of rebuilds on change.
    final onTop = ModalRoute.of(context)?.isCurrent ?? true;
    return Scaffold(
      body: FutureBuilder<ItemDetails?>(
        future: _details,
        builder: (context, snap) => CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              expandedHeight: 320,
              flexibleSpace: FlexibleSpaceBar(
                background: DetailsBackdrop(
                  item: widget.movie,
                  details: snap.data,
                  active: onTop,
                  fallback: Logo(
                    url: widget.movie.logo,
                    size: 320,
                    icon: kindIcon(widget.movie.kind),
                    fill: true,
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: DetailsInfo(
                item: widget.movie,
                details: snap.data,
                onPlay: widget.onPlay,
                watched: widget.isWatched?.call() ?? false,
                onWatched: widget.onWatched == null
                    ? null
                    : () => setState(widget.onWatched!),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
