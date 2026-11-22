// Settings → Guide: the guide sources (the provider's own first, then extra XMLTV URLs) with their last import,
// adding and removing extra URLs, the profile's time offset, "Refresh now", and the channels without a guide, which
// can be mapped to a guide channel by hand. Logic and storage are in the core (gerdtv_core::epg, library.rs).
// Debugging: a source's status line is the core's error text (already free of credentials).

import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';

/// The profile setting with the guide's time offset in whole hours (gerdtv_core SETTING_GUIDE_OFFSET).
const settingGuideOffset = 'guide_offset_hours';

class GuideSettings extends StatefulWidget {
  const GuideSettings({super.key, required this.session});
  final Session session;

  @override
  State<GuideSettings> createState() => _GuideSettingsState();
}

class _GuideSettingsState extends State<GuideSettings> {
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
    final s = widget.session;
    final offset =
        int.tryParse(_lib.setting(key: settingGuideOffset) ?? '') ?? 0;
    // Rebuilt by the parent's ListenableBuilder on the session, so a finished refresh shows its new status.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: Text(
            l10n.settingsGuide,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
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
                    src.builtin ? l10n.guideProvider : src.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(_status(l10n, src)),
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
        ListTile(
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
              _lib.setSetting(key: settingGuideOffset, value: '${h ?? 0}');
              setState(() {});
              await s.refreshGuide(
                force: true,
              ); // stored times carry the offset: re-import
            },
          ),
        ),
        ListTile(
          key: const Key('guide.refresh'),
          leading: s.guideRefreshing
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          title: Text(
            s.guideRefreshing ? l10n.guideRefreshing : l10n.guideRefresh,
          ),
          enabled: !s.guideRefreshing,
          onTap: () => s.refreshGuide(force: true),
        ),
        ListTile(
          key: const Key('guide.unmatched'),
          leading: const Icon(Icons.link_off),
          title: Text(l10n.guideUnmatched),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => UnmatchedChannelsScreen(library: _lib),
            ),
          ),
        ),
      ],
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

  @override
  void initState() {
    super.initState();
    _more();
  }

  Future<void> _more() async {
    if (_loading || _done) return;
    setState(() => _loading = true);
    final next = await widget.library.unmatchedChannels(
      limit: _page,
      offset: _channels.length,
    );
    if (!mounted) return;
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
      body: _channels.isEmpty && _done
          ? Center(child: Text(l10n.guideUnmatchedNone))
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
