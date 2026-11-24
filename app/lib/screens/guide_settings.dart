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

/// Community guides (owner decision): epgshare01 rebuilds one XMLTV file per country every day (about 4 days ahead,
/// gzip). A third party's server: files can move or go away, and the source's status line then shows the error.
/// The codes are the project's file names (`DE1` = Germany, `IN2` = India's second file), taken from its listing.
const communityGuideBase = 'https://epgshare01.online/epgshare01/epg_ripper_';
const communityGuides = [
  'AE1',
  'AL1',
  'AR1',
  'AT1',
  'AU1',
  'BA1',
  'BB1',
  'BE2',
  'BG1',
  'BR1',
  'BR2',
  'CA2',
  'CH1',
  'CL1',
  'CO1',
  'CR1',
  'CY1',
  'CZ1',
  'DE1',
  'DK1',
  'DO1',
  'EC1',
  'ES1',
  'FI1',
  'FR1',
  'GR1',
  'HK1',
  'HR1',
  'HU1',
  'ID1',
  'IE1',
  'IL1',
  'IN1',
  'IN2',
  'IN4',
  'IT1',
  'JM1',
  'JP1',
  'JP2',
  'KE1',
  'KR1',
  'KZ1',
  'LT1',
  'LU1',
  'LV1',
  'MN1',
  'MT1',
  'MX1',
  'MY1',
  'NG1',
  'NL1',
  'NO1',
  'NZ1',
  'PA1',
  'PE1',
  'PH2',
  'PL1',
  'PT1',
  'RO1',
  'RO2',
  'RS1',
  'SA2',
  'SE1',
  'SG1',
  'SK1',
  'SV1',
  'TH1',
  'TR1',
  'TR3',
  'UA1',
  'UK1',
  'US2',
  'UY1',
  'VN1',
  'ZA1',
];

String communityGuideUrl(String code) => '$communityGuideBase$code.xml.gz';

/// "DE", or "IN 2" for a country's second file.
String communityGuideLabel(String code) {
  final n = code.substring(2);
  return n == '1' ? code.substring(0, 2) : '${code.substring(0, 2)} $n';
}

/// A guide source's name in the list: "DE" for a community guide's file, the URL itself for any other.
String guideSourceLabel(String url) {
  final code = url.startsWith(communityGuideBase) && url.endsWith('.xml.gz')
      ? url.substring(communityGuideBase.length, url.length - 7)
      : null;
  return code != null && communityGuides.contains(code)
      ? communityGuideLabel(code)
      : url;
}

/// The source's full URL, selectable and with Copy (the list shows community guides by their short name).
Future<void> showGuideSourceUrl(BuildContext context, String url) {
  final l10n = AppLocalizations.of(context);
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(guideSourceLabel(url)),
      content: SelectableText(url),
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

/// Picks a community guide: a sheet with every country file; [onPick] gets its URL.
Future<void> pickCommunityGuide(
  BuildContext context,
  ValueChanged<String> onPick,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (context) {
    final l10n = AppLocalizations.of(context);
    return ListView(
      children: [
        ListTile(
          title: Text(l10n.guideCommunity),
          subtitle: Text(l10n.guideCommunityHint),
        ),
        for (final code in communityGuides)
          ListTile(
            key: Key('guide.community.$code'),
            title: Text(communityGuideLabel(code)),
            onTap: () {
              Navigator.of(context).pop();
              onPick(communityGuideUrl(code));
            },
          ),
      ],
    );
  },
);

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
                      : () => showGuideSourceUrl(context, src.url),
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
            onPressed: () => pickCommunityGuide(context, (url) async {
              await _lib.addGuideUrl(url: url);
              await widget.session.refreshGuide(force: true);
            }),
          ),
        ),
      ],
    );
  }
}

/// The profile's guide time offset in whole hours; changing it re-imports (stored times carry the offset).
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
      trailing: DropdownButton<int>(
        key: const Key('guide.offset'),
        value: offset.clamp(-12, 12),
        items: [
          for (var h = -12; h <= 12; h++)
            DropdownMenuItem(
              value: h,
              child: Text(l10n.guideOffsetHours(h > 0 ? '+$h' : '$h')),
            ),
        ],
        onChanged: (h) async {
          lib.setSetting(key: settingGuideOffset, value: '${h ?? 0}');
          setState(() {});
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
      appBar: AppBar(title: Text(l10n.guideUnmatched)),
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
              onChanged: (_) => setState(() => _found = _find()),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<ChannelRef>>(
              future: _found,
              builder: (context, snap) => ListView(
                children: [
                  for (final c in snap.data ?? const <ChannelRef>[])
                    ListTile(
                      title: Text(c.name),
                      subtitle: Text(c.id),
                      onTap: () async {
                        await widget.library.mapChannel(
                          itemKey: widget.item.id,
                          channel: c.id,
                        );
                        if (context.mounted) Navigator.of(context).pop(true);
                      },
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
