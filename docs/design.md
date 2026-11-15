# Visual design: "Signal Path"

The app keeps one layout on every page: instrument tabs on top, input meters on
the left, the instrument in the middle, and a status bar at the bottom. The
look is taken from the app icon. All tokens live in
`Sources/AnalyzerUI/Theme.swift`; views never use literal colours.

## Four levers

- **Type.** SF Pro at three sizes (12 body, 11 small, 9 label). Plot and panel
  titles are small tracked capitals (`SectionLabel`), placed inside the plot.
  Every changing number uses SF Mono so readouts don't jitter.
- **Palette.** Ink-navy neutrals (background, panel, raised, hairline, grid),
  slightly blue so the shell matches the icon. Data colours come from the
  icon's cyan → blue → violet ramp.
- **Density.** Dense and aligned, for long sessions. Hairline panel edges,
  14 pt window padding, 8 pt panel radius, 5 pt control radius.
- **Signature move.** Ladder meters: segmented LED bars lit along the icon
  ramp, cyan at low level through violet, red only above -3 dBFS.

## Colour meanings (the same on every page)

| Token | Means |
|---|---|
| `signal` (cyan) | The primary measurement trace |
| `signal2` (violet) | The second trace: phase, peak hold, LCS |
| `ramp` | Level or magnitude, low (cyan) to high (violet) |
| `warning` (amber) | Uncalibrated, trigger level, needs attention |
| `danger` (red) | Clipping and overs only |
| `good` (green) | Live input running |

Selected toggles are a cyan-tinted fill with a cyan edge (form and colour, not
colour alone). Buttons share one style (`RaisedButtonStyle`) with hover,
pressed and disabled states.
