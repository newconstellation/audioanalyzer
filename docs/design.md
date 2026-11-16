# Visual design

The window has three columns: an instrument rail on the left (icon plus short
name, Command-1 to Command-0), the instrument in the middle with a status bar
under it, and the input meter bridge on the right. The look is taken from the
app icon. All tokens live in `Sources/AnalyzerUI/Theme.swift`; views never use
literal colours.

## Four levers

- **Type.** SF Pro at three sizes (12 body, 11 small, 9 label). Plot and panel
  titles are small tracked capitals (`SectionLabel`) placed inside the plot.
  Readouts stay small. Every changing number uses SF Mono so readouts don't
  jitter.
- **Palette.** Near-black neutrals with a slight violet tint. The rail and
  meter bridge (`chrome`) are a step darker than the content. Colour is
  reserved for data.
- **Density.** Dense and aligned, for long sessions. Hairline edges, 8 pt panel
  radius, 5 pt control radius.
- **Signature move.** Frequency colour: every trace or bar on a frequency axis
  is coloured by frequency (`Theme.frequencyShading`), cyan lows through blue
  mids to violet highs, the icon's ramp. The same band has the same colour in
  the spectrum, octave bars, transfer function, polar phase, THD and decay
  views.

## Colour meanings (the same on every page)

| Token | Means |
|---|---|
| `frequencyShading` | A trace on a frequency axis, coloured by frequency |
| `ramp` | Level on meters, low (cyan) to high (violet) |
| `signal` / `signal2` | Traces with no frequency axis (scope, history) |
| `warning` (amber) | Uncalibrated, trigger level, needs attention |
| `danger` (red) | Clipping and overs only |
| `good` (green) | Live input running |

Selected toggles have a cyan-tinted fill and a cyan edge, so the state shows in
form as well as colour. Buttons share one style (`RaisedButtonStyle`) with
hover, pressed and disabled states.
