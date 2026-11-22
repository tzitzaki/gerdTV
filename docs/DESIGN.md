# Design

The shell (`app/lib/screens/shell.dart`): a navigation rail on windows at least 720 px wide (desktop, tablet, TV), a bottom bar below that (phones). Sections: Live TV, Guide, Movies, Series, Search, Settings. Tokens: `app/lib/theme.dart` (accent, spacing unit 8, radius 12, motion 150 ms, the wide-layout breakpoint). The rules it follows:
- Form factors: desktop/tablet (left sidebar, global search on top), phone (bottom navigation), TV (10-foot layout, left menu, D-pad only, no touch-only controls).
- Calm and uncluttered: the platform's default font, a small type scale, generous spacing, one accent colour, dark (default) and light themes at WCAG AA contrast, visible focus rings, large hit targets. Posters and logos do the visual work.
- Keyboard and remote: Tab and the arrow keys reach every control, and the focused one is always scrolled into view from either side (`revealFocus` in `app/lib/main.dart`). In the player: Up/Down switch channels, OK (Enter/Select) opens the channel list, Left/Right seek, Space pauses, S stops, P mini player, Esc/Back leaves.
- Settings (`app/lib/screens/settings_screen.dart`): the search field on top; at 720 px and wider the categories sit in a 260 px column beside the chosen category, below that the categories are a list that opens a page per category; a search shows the matches grouped under their category titles.
- Logo (`app/lib/screens/app_logo.dart`): four mockups drawn in code (screen, monogram, signal, frame) on a rounded `Tokens.ink` tile, picked in Settings → Appearance; it shows at the top of the rail, on the setup screen and in About, and is the app icon. `just logos` renders the launcher icons from the same painter.
- Every state is explicit: empty states say what to do next, loading uses skeleton rows, errors name what happened and offer one action. No modal dialogs except confirmations of destructive actions.
- Motion at most 150 ms, respecting the system's reduce-motion setting.
- Design tokens live in `app/lib/theme.dart`; widgets use only tokens.
