# Design

Phase 3 builds the shell. The rules it follows:
- Form factors: desktop/tablet (left sidebar, global search on top), phone (bottom navigation), TV (10-foot layout, left menu, D-pad only, no touch-only controls).
- Calm and uncluttered: the platform's default font, a small type scale, generous spacing, one accent colour, dark (default) and light themes at WCAG AA contrast, visible focus rings, large hit targets. Posters and logos do the visual work.
- Every state is explicit: empty states say what to do next, loading uses skeleton rows, errors name what happened and offer one action. No modal dialogs except confirmations of destructive actions.
- Motion at most 150 ms, respecting the system's reduce-motion setting.
- Design tokens are a Flutter `ThemeData` + `ThemeExtension` defined here once built; widgets use only tokens.
