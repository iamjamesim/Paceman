# Agent state motion

The Paceman face shares the Working, Needs input, and Finished expressions and
motion across the custom watch, iPhone Home screen, macOS menu panel, and
Omarchy panel. The iPhone and custom watch also share the Failed expression.
Motion supports the written state label; the label must remain understandable
when the mark is still or hidden.

| State | Expression | Repeating motion |
| --- | --- | --- |
| Working | Open eyes | Fade from full opacity to about 39% over 1.3 seconds, then back over 1.3 seconds. |
| Needs input | Chevron eyes | Rise and return over 320 ms each, then rest for 360 ms. The small app/panel mark travels 3 points; the watch font moves 6 display pixels. |
| Finished | Rounded arch eyes | Sway through ±4° rotation and ±2 points/pixels horizontally over 4.2 seconds. |
| Failed (iPhone and custom watch) | Crossed eyes | No repeating motion. |
| Idle | No activity face | No motion. |

Failed represents a confirmed terminal turn error. The custom watch shares the
state expressions with iPhone, but keeps its theme tint for routine states and
uses amber/red for input and failure.

The watch implementation in `watch_face_layout.c` is the timing reference. It
uses LVGL's ease-in-out Bezier for the fade and bounce; iPhone, macOS, and Omarchy
currently use a sine ease. Omarchy fades to 40% opacity; the watch and SwiftUI
marks fade to 100/255 (about 39%). These small differences are accepted at the
current mark sizes. SwiftUI samples the wall clock, so a newly visible mark may
enter partway through a cycle; the watch and Omarchy start at rest. Keep the
durations, directions, and rest period aligned when changing a surface; revisit
the curves or start phase only if a visible mismatch appears.

Playback follows the surface's visibility and freshness rules:

- The custom watch animates while its face is awake. Repeated snapshots of the
  same state do not restart the cycle; sleep cancels motion and wake starts it
  again.
- iPhone Home animates current activity only while the app is active and the
  mark is visible. Historical activity is muted and still. Reduce Motion keeps
  the mark still.
- The macOS panel animates while its mark is visible and Reduce Motion is off.
  Omarchy animates while its panel is open and the source is running and sharing.
- ActivityKit Live Activities, including the Dynamic Island and Apple Watch
  Smart Stack tile, animate each fresh state change once, then hold still.
  Working fades to 100/255 and back once in 2 seconds; Needs input plays two
  bounces, each with a 320 ms rise, 320 ms return, and 360 ms rest; Finished
  completes one full ±4°/±2-point sway in 2 seconds. Idle, stale activity,
  Reduce Motion, Failed, and reduced-luminance displays stay still. ActivityKit cannot
  run the repeating cycles used by the other surfaces.

The large brand mark and decorative previews are not agent-state indicators and
do not use this motion.
