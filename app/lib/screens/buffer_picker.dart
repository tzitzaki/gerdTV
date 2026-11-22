// The buffer preset choice (Settings → Playback and the player's "Buffer for this channel"): Fast zap ~2 s,
// Balanced ~8 s, Smooth ~30 s, Max smooth ~90 s, Custom 1–300 s. More buffer means a later but smoother start and
// fewer stutters on a slow line (docs/SPEC.md, "Buffer").

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../src/rust/api/playback.dart';
import '../theme.dart';

String presetLabel(AppLocalizations l10n, BufferChoice c) => switch (c.preset) {
  BufferPreset.fastZap => l10n.bufferFastZap,
  BufferPreset.balanced => l10n.bufferBalanced,
  BufferPreset.smooth => l10n.bufferSmooth,
  BufferPreset.maxSmooth => l10n.bufferMaxSmooth,
  BufferPreset.custom =>
    '${l10n.bufferCustom}: ${l10n.secondsShort(c.seconds)}',
};

class BufferPicker extends StatefulWidget {
  const BufferPicker({super.key, required this.value, required this.onChanged});
  final BufferChoice value;
  final ValueChanged<BufferChoice> onChanged;

  @override
  State<BufferPicker> createState() => _BufferPickerState();
}

class _BufferPickerState extends State<BufferPicker> {
  late double _custom = widget.value.preset == BufferPreset.custom
      ? widget.value.seconds.toDouble()
      : 45;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final named = {
      BufferPreset.fastZap: (l10n.bufferFastZap, 2),
      BufferPreset.balanced: (l10n.bufferBalanced, 8),
      BufferPreset.smooth: (l10n.bufferSmooth, 30),
      BufferPreset.maxSmooth: (l10n.bufferMaxSmooth, 90),
    };
    return RadioGroup<BufferPreset>(
      groupValue: widget.value.preset,
      onChanged: (p) {
        if (p == null) return;
        widget.onChanged(
          BufferChoice(
            preset: p,
            seconds: p == BufferPreset.custom ? _custom.round() : named[p]!.$2,
          ),
        );
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final e in named.entries)
            RadioListTile<BufferPreset>(
              key: Key('buffer.${e.key.name}'),
              value: e.key,
              title: Text(e.value.$1),
            ),
          RadioListTile<BufferPreset>(
            key: const Key('buffer.custom'),
            value: BufferPreset.custom,
            title: Text(
              '${l10n.bufferCustom}: ${l10n.secondsShort(_custom.round())}',
            ),
          ),
          if (widget.value.preset == BufferPreset.custom)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Tokens.space * 2),
              child: Slider(
                min: 1,
                max: 300,
                divisions: 299,
                value: _custom,
                label: l10n.secondsShort(_custom.round()),
                onChanged: (v) => setState(() => _custom = v),
                onChangeEnd: (v) => widget.onChanged(
                  BufferChoice(preset: BufferPreset.custom, seconds: v.round()),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
