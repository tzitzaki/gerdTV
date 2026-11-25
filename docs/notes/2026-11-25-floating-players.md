# Floating players and lock screen

Started 16:10. Branch feat/floating-players. One commit per step.

## Steps
1. Volume survives engine switches and zapping (started 16:10)
2. Desktop mini player: hidden buttons, mute, M key
3. iOS: the floating window closes on return
4. iOS: no black frames on a renderer switch
5. iOS: software decoding while floating
6. iOS: PiP flag earlier, log lines
7. iOS button: one picture (player closes, bar shows the logo)
8. Lock screen card (iOS Now Playing, Android media session)
9. Wrap-up and release

## Decisions
- Buttons by tap or hover, 3 s; double-click does nothing; Now Playing card with play/pause only, no Live Activity.
