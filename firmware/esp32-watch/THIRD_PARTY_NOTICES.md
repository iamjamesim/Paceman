# Third-party notices

The generated C arrays under `firmware/main/fonts/` are bitmap subsets produced
from JetBrains Mono Nerd Font 3.5.0 with `lv_font_conv` 1.5.3. They are checked
in so firmware builds do not require Node.js or host fonts.

- JetBrains Mono is copyright the JetBrains Mono Project Authors and licensed
  under the SIL Open Font License 1.1. A copy is included at
  `firmware/main/fonts-OFL.txt`.
- Nerd Fonts provides the patched font and documents the authors, origins, and
  licenses of its bundled glyph sets in its
  [glyph-source table](https://github.com/ryanoasis/nerd-fonts/blob/master/src/glyphs/README.md).
- The location and bolt glyphs are from Font Awesome 6.5.1, whose icons are
  licensed under CC BY 4.0.
- The battery glyphs are from Material Design Icons and licensed under Apache
  2.0.
- The partly-cloudy glyph is from Weather Icons 2.0.10 and licensed under the
  SIL Open Font License 1.1.

Run `tools/generate-fonts.sh` to regenerate the subsets from an installed
JetBrains Mono Nerd Font. The script pins the converter version and records the
selected Unicode ranges in every generated source file. Byte-identical output
also requires the 3.5.0 input fonts used for this checkpoint:

| Input font | SHA-256 |
| --- | --- |
| JetBrainsMonoNerdFont-Regular.ttf | `1767e08e6b207eb57c114e833b817e26c6a7625bbcf474e3b4dd0f73c10e5bdc` |
| JetBrainsMonoNerdFont-Bold.ttf | `39878d753c3ae005172b8ee4c4f72c4e6a5c641ddb844110d66bf9eba77dc90a` |

Forecast data is provided by [Open-Meteo.com](https://open-meteo.com/) under
the [Creative Commons Attribution 4.0 International
license](https://creativecommons.org/licenses/by/4.0/). Omarchy Watch rounds
temperature values and maps WMO weather codes to its own text and icons.
