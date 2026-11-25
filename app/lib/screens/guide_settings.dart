// Settings → Guide: the guide sources (the provider's own first, then extra XMLTV URLs) with their last import,
// adding and removing extra URLs, the profile's time offset, "Refresh now", and the channels without a guide, which
// can be mapped to a guide channel by hand; community guide presets add a country's XMLTV file in one tap. Several
// sources work at once; where they overlap, the provider's guide wins (rebuild_matches in gerdtv_core::epg). Logic
// and storage are in the core (gerdtv_core::epg, library.rs).
// Debugging: a source's status line is the core's error text (already free of credentials).

import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';

/// The profile setting with the guide's time offset in whole hours (gerdtv_core SETTING_GUIDE_OFFSET).
const settingGuideOffset = 'guide_offset_hours';

/// A project that publishes guide files, one per country or part: third parties' servers, so files can move or go
/// away, and the source's status line then shows the error. A file's name is its label ("IN2" = India's second file).
class GuideProject {
  const GuideProject(this.name, this._before, this._after, this._files);

  final String name;
  final String _before, _after, _files;

  List<String> get files => _files.split(' ');

  /// The file's URL: projects name countries in lower case, epgshare01 and Rytec in upper case.
  String url(String file) =>
      '$_before${_before.endsWith('_') || _before.endsWith('rytec') ? file : file.toLowerCase()}$_after';

  /// The file [url] is, or null.
  String? fileOf(String url) {
    for (final f in files) {
      if (this.url(f) == url) return f;
    }
    return null;
  }

  /// "DE", "IN 2", "DE Basic", "germany 1".
  static String label(String file) => file
      .replaceFirstMapped(RegExp(r'^([A-Z]{2})1$'), (m) => m[1]!)
      .replaceFirstMapped(RegExp(r'([A-Za-z])(\d)$'), (m) => '${m[1]} ${m[2]}')
      .replaceAll('_', ' ');
}

/// The community guides (owner decision), from each project's own listing. Left out: free-epg's DE and FR (the same
/// channels as epgshare01's).
const guideProjects = [
  GuideProject(
    'epgshare01',
    'https://epgshare01.online/epgshare01/epg_ripper_',
    '.xml.gz',
    'AE1 AL1 AR1 AT1 AU1 BA1 BB1 BE2 BG1 BR1 BR2 CA2 CH1 CL1 CO1 CR1 CY1 CZ1 DE1 DK1 DO1 EC1 ES1 FI1 FR1 '
        'GR1 HK1 HR1 HU1 ID1 IE1 IL1 IN1 IN2 IN4 IT1 JM1 JP1 JP2 KE1 KR1 KZ1 LT1 LU1 LV1 MN1 MT1 MX1 MY1 NG1 '
        'NL1 NO1 NZ1 PA1 PE1 PH2 PL1 PT1 RO1 RO2 RS1 SA2 SE1 SG1 SK1 SV1 TH1 TR1 TR3 UA1 UK1 US2 UY1 VN1 ZA1 '
        'BEIN1 SPORTKLUB1',
  ),
  GuideProject(
    'free-epg',
    'https://free-epg.de/api/epg/',
    '.xml.gz',
    'AE AL AM AR AT AU BA BE BG BO BR BS BY CA CH CL CN CO CR CW CZ DK DO EC EG ES FI GB GE GH GR GT HK '
        'HN HR HU ID IL IN IS IT JM JP KR LB LK LT LU LV ME MK MT MX MY NG NI NL NO NZ PA PE PH PL PT PY RO '
        'RS RU SA SE SG SI SV TH TR TT TW UA UG US UY VE VN ZA ZW',
  ),
  // No HTTPS on its server (it timed out): the one exception to "plain HTTP is for providers only" (owner decision).
  GuideProject(
    'Rytec',
    'http://www.xmltvepg.nl/rytec',
    '.xz',
    'AT_Basic CH_Basic CZ_Basic DE_Basic DE_Common DE_SportMovies ES_Basic ES_Misc ES_SportMovies '
        'FR_SportMovies GR_Basic GR_SportMovies HU_Basic HU_SportMovies IT_Basic IT_SportMovies NL_Basic '
        'PL_Basic PL_Misc PL_SportMovies RO_Basic RO_SportMovies UK_Basic UK_SportMovies',
  ),
  // Streaming channels, about a day ahead.
  GuideProject(
    'Pluto TV',
    'https://i.mjh.nz/PlutoTV/',
    '.xml.gz',
    'AR BR CA CL DE DK ES FR GB IT MX NO SE US',
  ),
  GuideProject(
    'Samsung TV Plus',
    'https://i.mjh.nz/SamsungTVPlus/',
    '.xml.gz',
    'AT CA CH DE ES FR GB IN IT KR US',
  ),
  // At most 20 downloads per file and day (its FAQ); two days of programmes.
  GuideProject(
    'open-epg',
    'https://www.open-epg.com/files/',
    '.xml.gz',
    'albania1 austria1 bosnia1 croatia1 germany1 germany2 germany3 germany4 germany5 germany6 italy1 '
        'italy2 italy3 macedonia1 montenegro1 serbia1 serbia2 slovenia1 switzerland1 turkey1 turkey2 turkey3 '
        'turkey4 unitedkingdom1 unitedkingdom2 unitedkingdom3 unitedkingdom4 unitedkingdom5',
  ),
];

/// A guide source's name in the list: "AT · free-epg" for a community guide's file, the URL itself for any other.
String guideSourceLabel(String url) {
  for (final p in guideProjects) {
    final file = p.fileOf(url);
    if (file != null) return '${GuideProject.label(file)} · ${p.name}';
  }
  return url;
}

/// The source's full URL, selectable and with Copy (the list shows community guides by their short name).
Future<void> showGuideSourceUrl(
  BuildContext context,
  String url, {
  int offsetHours = 0,
  ValueChanged<int>? onOffset,
}) {
  final l10n = AppLocalizations.of(context);
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(guideSourceLabel(url)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(url),
          if (onOffset != null) ...[
            const SizedBox(height: Tokens.space * 2),
            Text(l10n.guideOffset),
            OffsetPicker(
              key: const Key('guide.source.offset'),
              value: offsetHours,
              onChanged: onOffset,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: url)),
          child: Text(l10n.copy),
        ),
        TextButton(
          key: const Key('guide.source.close'),
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.close),
        ),
      ],
    ),
  );
}

/// Picks a community guide: a sheet with each project's files, without those in [added] (URLs of the profile's
/// sources: a guide listed above must not be offered again); [onPick] gets the picked one's URL.
Future<void> pickCommunityGuide(
  BuildContext context,
  ValueChanged<String> onPick, {
  required Set<String> added,
}) {
  final query = ValueNotifier('');
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      final l10n = AppLocalizations.of(context);
      return SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Column(
          children: [
            ListTile(
              title: Text(l10n.guideCommunity),
              subtitle: Text(l10n.guideCommunityHint),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Tokens.space * 2),
              child: TextField(
                key: const Key('guide.community.search'),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: l10n.guideCommunitySearch,
                ),
                onChanged: (v) => query.value = v.trim().toLowerCase(),
              ),
            ),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: query,
                builder: (context, q, _) {
                  final rows = <Widget>[];
                  for (final p in guideProjects) {
                    final open = p.files.where(
                      (f) =>
                          !added.contains(p.url(f)) &&
                          '${GuideProject.label(f)} ${p.name}'
                              .toLowerCase()
                              .contains(q),
                    );
                    if (open.isEmpty) continue;
                    rows.add(
                      ListTile(
                        title: Text(
                          p.name,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                    );
                    for (final f in open) {
                      rows.add(
                        ListTile(
                          key: Key('guide.community.${p.name}.$f'),
                          title: Text(GuideProject.label(f)),
                          onTap: () {
                            Navigator.of(context).pop();
                            onPick(p.url(f));
                          },
                        ),
                      );
                    }
                  }
                  if (rows.isEmpty) {
                    return Center(child: Text(l10n.guideCommunityNone));
                  }
                  return ListView(children: rows);
                },
              ),
            ),
          ],
        ),
      );
    },
  ).whenComplete(query.dispose);
}

/// The guide sources with their last import, and the field that adds an extra XMLTV URL. Rebuilt by the settings
/// screen's ListenableBuilder on the session, so a finished refresh shows its new status.
class GuideSources extends StatefulWidget {
  const GuideSources({super.key, required this.session});
  final Session session;

  @override
  State<GuideSources> createState() => _GuideSourcesState();
}

class _GuideSourcesState extends State<GuideSources> {
  final _url = TextEditingController();
  Library get _lib => widget.session.library!;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _addUrl() async {
    final url = _url.text.trim();
    if (!url.startsWith('http')) return;
    await _lib.addGuideUrl(url: url);
    _url.clear();
    await widget.session.refreshGuide(force: true);
  }

  String _status(AppLocalizations l10n, GuideSourceInfo s) {
    if (s.status.isNotEmpty) return l10n.guideFailed(s.status);
    if (s.lastFetch == 0) return l10n.guideNever;
    final at = DateTime.fromMillisecondsSinceEpoch(s.lastFetch * 1000);
    final locale = Localizations.localeOf(context).toLanguageTag();
    return l10n.guideSourceStatus(
      s.matched,
      s.channels,
      s.programmes,
      '${DateFormat.E(locale).format(at)} ${DateFormat.Hm(locale).format(at)}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FutureBuilder<List<GuideSourceInfo>>(
          // A new future on every rebuild (the session notifies after each import): the list reloads, and keeps
          // showing the previous rows while it does.
          future: _lib.guideSources(),
          builder: (context, snap) => Column(
            children: [
              for (final src in snap.data ?? const <GuideSourceInfo>[])
                ListTile(
                  key: Key('guide.source.${src.builtin ? 'builtin' : src.id}'),
                  leading: Icon(
                    src.status.isNotEmpty
                        ? Icons.error_outline
                        : Icons.calendar_view_day_outlined,
                  ),
                  title: Text(
                    src.builtin
                        ? l10n.guideProvider
                        : guideSourceLabel(src.url),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(_status(l10n, src)),
                  onTap: src.builtin
                      ? null
                      : () => showGuideSourceUrl(
                          context,
                          src.url,
                          offsetHours: src.offsetHours,
                          onOffset: (h) async {
                            await _lib.setGuideOffset(id: src.id, hours: h);
                            // Stored times carry the offset: re-import.
                            await widget.session.refreshGuide(force: true);
                          },
                        ),
                  trailing: src.builtin
                      ? null
                      : IconButton(
                          tooltip: l10n.remove,
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            await _lib.removeGuideSource(id: src.id);
                            setState(() {});
                          },
                        ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Tokens.space * 2),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('guide.url'),
                  controller: _url,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: l10n.guideAddUrl,
                    hintText: l10n.guideUrlHint,
                  ),
                  onSubmitted: (_) => _addUrl(),
                ),
              ),
              const SizedBox(width: Tokens.space),
              TextButton(
                key: const Key('guide.add'),
                onPressed: _addUrl,
                child: Text(l10n.add),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Tokens.space),
          child: TextButton.icon(
            key: const Key('guide.community'),
            icon: const Icon(Icons.public),
            label: Text(l10n.guideCommunityAdd),
            onPressed: () async {
              // Read now: a source removed or pasted since the last build counts too.
              final added = {
                for (final src in await _lib.guideSources()) src.url,
              };
              if (!context.mounted) return;
              await pickCommunityGuide(context, (url) async {
                await _lib.addGuideUrl(url: url);
                await widget.session.refreshGuide(force: true);
              }, added: added);
            },
          ),
        ),
      ],
    );
  }
}

/// Whole hours from −12 to +12; keeps the picked value itself (its dialog isn't rebuilt by the session).
class OffsetPicker extends StatefulWidget {
  const OffsetPicker({super.key, required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<OffsetPicker> createState() => _OffsetPickerState();
}

class _OffsetPickerState extends State<OffsetPicker> {
  late int _value = widget.value.clamp(-12, 12);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return DropdownButton<int>(
      value: _value,
      items: [
        for (var h = -12; h <= 12; h++)
          DropdownMenuItem(
            value: h,
            child: Text(l10n.guideOffsetHours(h > 0 ? '+$h' : '$h')),
          ),
      ],
      onChanged: (h) {
        if (h == null) return;
        setState(() => _value = h);
        widget.onChanged(h);
      },
    );
  }
}

/// The provider guide's time offset in whole hours; changing it re-imports (stored times carry the offset).
class GuideOffset extends StatefulWidget {
  const GuideOffset({super.key, required this.session});
  final Session session;

  @override
  State<GuideOffset> createState() => _GuideOffsetState();
}

class _GuideOffsetState extends State<GuideOffset> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final lib = widget.session.library!;
    final offset =
        int.tryParse(lib.setting(key: settingGuideOffset) ?? '') ?? 0;
    return ListTile(
      title: Text(l10n.guideOffset),
      subtitle: Text(l10n.guideOffsetHint),
      trailing: OffsetPicker(
        key: const Key('guide.offset'),
        value: offset,
        onChanged: (h) async {
          lib.setSetting(key: settingGuideOffset, value: '$h');
          await widget.session.refreshGuide(
            force: true,
          ); // stored times carry the offset: re-import
        },
      ),
    );
  }
}

/// "Refresh now", with a spinner while an import runs.
class GuideRefresh extends StatelessWidget {
  const GuideRefresh({super.key, required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = session;
    return ListTile(
      key: const Key('guide.refresh'),
      leading: s.guideRefreshing
          ? const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh),
      title: Text(s.guideRefreshing ? l10n.guideRefreshing : l10n.guideRefresh),
      enabled: !s.guideRefreshing,
      onTap: () => s.refreshGuide(force: true),
    );
  }
}

/// Opens the channels without a guide, where each can be mapped by hand.
class GuideUnmatched extends StatelessWidget {
  const GuideUnmatched({super.key, required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListTile(
      key: const Key('guide.unmatched'),
      leading: const Icon(Icons.link_off),
      title: Text(l10n.guideUnmatched),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => UnmatchedChannelsScreen(library: session.library!),
        ),
      ),
    );
  }
}

/// Live channels without a guide; tapping one picks its guide channel.
class UnmatchedChannelsScreen extends StatefulWidget {
  const UnmatchedChannelsScreen({super.key, required this.library});
  final Library library;

  @override
  State<UnmatchedChannelsScreen> createState() =>
      _UnmatchedChannelsScreenState();
}

class _UnmatchedChannelsScreenState extends State<UnmatchedChannelsScreen> {
  // Paged like the browse lists: a provider can have thousands of channels without a guide.
  static const _page = 200;
  final List<ChannelRef> _channels = [];
  bool _loading = false;
  bool _done = false;
  // The search runs in the core over all of them (not just the loaded pages); each keystroke starts over, and an
  // answer to an older query is dropped (_query no longer matches).
  final _search = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _more();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _searchFor(String text) {
    setState(() {
      _query = text.trim();
      _channels.clear();
      _done = false;
      _loading = false;
    });
    _more();
  }

  Future<void> _more() async {
    if (_loading || _done) return;
    final query = _query;
    setState(() => _loading = true);
    final next = await widget.library.unmatchedChannels(
      limit: _page,
      offset: _channels.length,
      query: query,
    );
    if (!mounted || query != _query) return;
    setState(() {
      _channels.addAll(next);
      _done = next.length < _page;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.guideUnmatched),
        actions: [
          IconButton(
            key: const Key('guide.mapped'),
            tooltip: l10n.guideMapped,
            icon: const Icon(Icons.link),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => MappedChannelsScreen(library: widget.library),
                ),
              );
              // An undone mapping may be back in this list.
              if (mounted) _searchFor(_query);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(Tokens.space),
            child: TextField(
              key: const Key('guide.unmatchedSearch'),
              controller: _search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: l10n.searchHintChannels,
              ),
              onChanged: _searchFor,
            ),
          ),
          Expanded(child: _list(l10n)),
        ],
      ),
    );
  }

  Widget _list(AppLocalizations l10n) {
    return _channels.isEmpty && _done
        ? Center(
            child: Text(
              _query.isEmpty
                  ? l10n.guideUnmatchedNone
                  : l10n.searchNoResults(_query),
            ),
          )
        : NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.extentAfter < 600) _more();
              return false;
            },
            child: ListView.builder(
              itemCount: _channels.length + (_loading ? 1 : 0),
              itemBuilder: (context, i) {
                if (i == _channels.length) {
                  return const Padding(
                    padding: EdgeInsets.all(Tokens.space * 2),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final c = _channels[i];
                return ListTile(
                  key: Key('guide.unmatched.${c.id}'),
                  title: Text(c.name),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final mapped = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder: (_) => PickGuideChannelScreen(
                          library: widget.library,
                          item: c,
                        ),
                      ),
                    );
                    // A mapped channel has a guide now: it leaves the list.
                    if (mapped == true) setState(() => _channels.remove(c));
                  },
                );
              },
            ),
          );
  }
}

/// The channels mapped by hand; Undo goes back to the automatic match.
class MappedChannelsScreen extends StatefulWidget {
  const MappedChannelsScreen({super.key, required this.library});
  final Library library;

  @override
  State<MappedChannelsScreen> createState() => _MappedChannelsScreenState();
}

class _MappedChannelsScreenState extends State<MappedChannelsScreen> {
  late Future<List<MappedChannel>> _mapped = widget.library.mappedChannels();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.guideMapped)),
      body: FutureBuilder<List<MappedChannel>>(
        future: _mapped,
        builder: (context, snap) {
          final rows = snap.data;
          if (rows == null) return const SizedBox.shrink();
          if (rows.isEmpty) return Center(child: Text(l10n.guideMappedNone));
          return ListView(
            children: [
              for (final m in rows)
                ListTile(
                  title: Text(m.name),
                  subtitle: Text(m.guide),
                  trailing: TextButton(
                    key: Key('guide.unmap.${m.id}'),
                    onPressed: () async {
                      await widget.library.mapChannel(itemKey: m.id);
                      if (!mounted) return;
                      setState(() {
                        _mapped = widget.library.mappedChannels();
                      });
                    },
                    child: Text(l10n.guideMappedUndo),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Searches the guide's channels by name or id (empty: all, by name); tapping one maps [item] to it (pops with true).
class PickGuideChannelScreen extends StatefulWidget {
  const PickGuideChannelScreen({
    super.key,
    required this.library,
    required this.item,
  });
  final Library library;
  final ChannelRef item;

  @override
  State<PickGuideChannelScreen> createState() => _PickGuideChannelScreenState();
}

class _PickGuideChannelScreenState extends State<PickGuideChannelScreen> {
  // Starts empty: the provider's channel name rarely matches the guide's spelling, and empty lists every channel.
  final _query = TextEditingController();
  late Future<List<ChannelRef>> _found = _find();
  late final _suggested = widget.library.suggestGuideChannels(
    itemKey: widget.item.id,
    limit: 3,
  );

  Widget _row(ChannelRef c, {bool suggested = false}) => ListTile(
    key: suggested ? Key('guide.suggested.${c.id}') : null,
    leading: suggested ? const Icon(Icons.auto_awesome) : null,
    title: Text(c.name),
    subtitle: Text(c.id),
    onTap: () async {
      await widget.library.mapChannel(itemKey: widget.item.id, channel: c.id);
      if (mounted) Navigator.of(context).pop(true);
    },
  );

  Future<List<ChannelRef>> _find() =>
      widget.library.findGuideChannels(query: _query.text.trim(), limit: 100);

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.guidePickChannel(widget.item.name))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(Tokens.space),
            child: TextField(
              key: const Key('guide.find'),
              controller: _query,
              autofocus: true,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: l10n.guideFindHint,
              ),
              onChanged: (_) => setState(() {
                _found = _find();
              }),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<ChannelRef>>(
              future: _found,
              builder: (context, snap) => ListView(
                children: [
                  // Likely ones first (the core's guess, confirmed by the tap); typing is a search of one's own.
                  if (_query.text.isEmpty)
                    FutureBuilder<List<ChannelRef>>(
                      future: _suggested,
                      builder: (context, snap) => Column(
                        children: [
                          for (final c in snap.data ?? const <ChannelRef>[])
                            _row(c, suggested: true),
                        ],
                      ),
                    ),
                  for (final c in snap.data ?? const <ChannelRef>[]) _row(c),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
