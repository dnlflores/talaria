# Offline transcript presentation check

The Debug-only `--transcript-preview` launch argument renders the production work
log, Markdown answer and tool inspector with local fixture data. It bypasses
`AppModel.launch()` and does not connect, sign in or create a conversation.
Release builds do not include the fixture or launch-argument branch.

```sh
xcodegen generate
xcodebuild test -project Talaria.xcodeproj -scheme Talaria \
  -destination 'platform=iOS Simulator,id=<simulator UUID>' \
  -only-testing:TalariaUITests/TranscriptPresentationTests \
  -resultBundlePath <scratch directory>/transcript.xcresult \
  CODE_SIGNING_ALLOWED=NO
xcrun xcresulttool export attachments \
  --path <scratch directory>/transcript.xcresult \
  --output-path <scratch directory>/transcript-shots
```

The test captures all six themes in light and dark, asserts both reasoning and
commentary from one item are visible, checks the 44-point tool hit target, opens
the input/output inspector, and collapses/reopens the work log. Attachments are
named `transcript-<family>-<light|dark>`. The fixture includes completed/duration,
failed and running tools, plus commentary between calls.

For manual launches set `SIMCTL_CHILD_TALARIA_PREVIEW_THEME` to `standard`,
`t3Chat`, `grove`, `ocean`, `ember`, or `iris`, and
`SIMCTL_CHILD_TALARIA_PREVIEW_APPEARANCE` to `light` or `dark`, then use
`xcrun simctl launch <UUID> <bundle ID> --transcript-preview`.

`swift test --filter WorkContentTests` covers the shared presentation projection:
reasoning precedes commentary without discarding either; whitespace-only content
produces no empty block. Markdown source is preserved verbatim for commentary.
Semantic colors live in `Palette`'s extension in `Theme.swift`, not the generated
palette file. Labels, icons, an explicit error state, and the reasoning rail make
the hierarchy understandable without color alone.
