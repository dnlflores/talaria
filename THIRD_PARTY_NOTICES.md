# Third-party notices

Talaria has no third-party code dependencies. It does carry design data and
fonts from the projects below.

## T3 Code (color tokens)

`Talaria/Theme/Palettes.generated.swift` is generated from the theme tokens of
T3 Code's mobile app (`apps/mobile/generated-uniwind-themes.css`) by
`scripts/generate-palettes.mjs`. The type scale in
`Talaria/Theme/Typography.swift` follows the same app. The app's layout was
rebuilt by hand in SwiftUI to resemble it; no T3 Code source code is included.

Source: https://github.com/pingdotgg/t3code

```
MIT License

Copyright (c) 2026 T3 Tools Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## DM Sans (fonts)

`Talaria/Resources/Fonts/DMSans-*.ttf` are the static Regular, Italic, Medium,
SemiBold and Bold faces of DM Sans, copyright 2014 The DM Sans Project Authors
(https://github.com/googlefonts/dm-fonts), under the SIL Open Font License 1.1.
The full license text ships beside the fonts in
`Talaria/Resources/Fonts/OFL.txt`.

## Hermes Agent (protocol)

Talaria is a client of the Hermes Agent gateway by Nous Research (MIT). Method
names and payload shapes follow the gateway contract that ships with Hermes
(`apps/shared/src/gateway-contract.openrpc.json`). No Hermes source code is
included.

Source: https://github.com/NousResearch/hermes-agent
