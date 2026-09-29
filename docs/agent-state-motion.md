# Agent state motion

The same Paceman face identifies agent state on iPhone, Live Activities, the
Mac and Omarchy panels, and the custom watch. Written state labels carry the
meaning when animation is unavailable.

| State | Eyes | Repeating motion on active app or watch face |
| --- | --- | --- |
| Working | Open | Opacity fades from full to about 39% and back, 1.3 seconds each way. |
| Needs input | Chevrons | Rise and return, 320 ms each, then rest 360 ms. |
| Finished | Rounded arches | Sway ±4° and ±2 points/pixels over 4.2 seconds. |
| Failed | Crossed | Still. |
| Idle | No activity face | None. |

The small app/panel mark rises 3 points; the watch font rises 6 pixels. Live
Activities and the Apple Watch Smart Stack play one short transition instead
of a repeating cycle. Historical activity, Reduce Motion, reduced-luminance
surfaces, and a sleeping watch remain still. Repeated snapshots of the same
state do not restart a watch animation. The large decorative brand mark is not
an agent-state indicator.
