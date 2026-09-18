# Fonts

The UI asks for two faces by name:

| face | used for | where to get it |
| --- | --- | --- |
| `Michroma-Regular` | display type — wordmark, big numbers, section labels | [Google Fonts · Michroma](https://fonts.google.com/specimen/Michroma) (OFL) |
| `VT323-Regular` | the pixel readouts — clock, timecode, dB, counts | [Google Fonts · VT323](https://fonts.google.com/specimen/VT323) (OFL) |

Drop the `.ttf` files next to this README. `ios/project.yml` already lists them under
`UIAppFonts`, so nothing else has to change — XcodeGen will pick them up as resources
on the next `xcodegen generate`.

If they are missing the app still builds and runs: `Font.custom(_:size:relativeTo:)`
falls back to the SF Rounded text style it was anchored to, which is why every call
site passes `relativeTo:`. Body copy is always SF Rounded; the pixel face is reserved
for numbers on purpose — that is what keeps the Y2K look readable on a phone.
