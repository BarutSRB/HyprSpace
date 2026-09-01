# AeroSpace AX dump corpus

125 real-app accessibility dumps vendored from the AeroSpace window manager, used as a differential
corpus for OmniWM's window classifier. Each file is one captured window: its AX attribute tree, the
owning app's activation policy and bundle id, its CoreGraphics window level, and AeroSpace's own
classification of it (`Aero.AxUiElementWindowType`: `window` | `dialog` | `popup`).

They are data files, not source, so the repository's mandatory GPL header does not apply to them.

## Upstream

- Project: AeroSpace — https://github.com/nikitabobko/AeroSpace
- Commit: `d56e1637c3a1ed660d0cadd7534e94fb3218d1c3` (2026-07-11)
- Path: `axDumps/`
- Produced by: `aerospace debug-windows`

## Local modifications

The upstream `axDumps/scenario_firefox_google_meet_share_window/` subdirectory was flattened into this
directory with a `scenario_gmeet_share_` filename prefix, so the loader can do a single flat scan. File
contents are unmodified. Upstream's `README.md` files were not copied.

## How these are used

`AeroSpaceCorpusTests` projects each dump into a `WindowClassificationInput` and runs OmniWM's real
rule engine over it, asserting against `expectations.json` in this directory.

`Aero.AxUiElementWindowType` is **evidence, not ground truth** — it records what AeroSpace decides, and
OmniWM deliberately differs on some windows. Every divergence carries a `note` in `expectations.json`
explaining why. Do not treat a mismatch with AeroSpace as automatically a bug in OmniWM, and do not
regenerate `expectations.json` from OmniWM's own output: that would pin current behaviour and destroy
the corpus's value.

These dumps carry no WindowServer tags or parent-window id. The loader synthesises `parentId: 0`, so the
corpus exercises only parentless structural admission and cannot validate the hard exclusion for a distinct
WindowServer parent.

## Licence

AeroSpace is MIT-licensed. The notice below travels with these files.

```
MIT License

Copyright (c) 2023 Nikita Bobko

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
