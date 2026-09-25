# Agent state motion

The Paceman face uses the same expression and motion for each agent state across
the custom watch, iPhone Home screen, macOS menu panel, and Omarchy panel. Motion
supports the written state label; the label must remain understandable when the
mark is still or hidden.

| State | Expression | Repeating motion |
| --- | --- | --- |
| Working | Open eyes | Fade from full opacity to about 39% over 1.3 seconds, then back over 1.3 seconds. |
| Needs input | Chevron eyes | Rise and return over 320 ms each, then rest for 360 ms. The small app/panel mark travels 3 points; the watch font moves 6 display pixels. |
| Finished | Rounded arch eyes | Sway through ±4° rotation and ±2 points/pixels horizontally over 4.2 seconds. |
| Idle | No activity face | No motion. |

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
- ActivityKit Live Activities, including the Apple Watch Smart Stack tile, show
  the same expressions but do not run continuous loops. The system may animate
  a content change briefly.

The large brand mark and decorative previews are not agent-state indicators and
do not use this motion.
