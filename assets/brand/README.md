# OmniWM brand assets

The canonical geometry is the reference-faithful eight-ray mark in `source/omniwm-mark-color.svg`. Normal-size app, launch, and web assets use that geometry unchanged. The status and favicon silhouettes use the optical microcut in `source/omniwm-status-template.svg` so the center dot and all eight rays remain separate at 14 px.

## Palette

| Role | Hex |
| --- | --- |
| Terracotta | `#A65136` |
| Brown outline and wordmark | `#763424` |
| Warm ivory | `#F8F4EC` |

Use the color artwork for the app and website. Use the template PDF for native macOS interface placement; AppKit supplies black in light mode and white in dark mode. Do not add a baked rounded mask, recolor individual rays, add text inside the mark, or alter the center-dot separation.

Regenerate and validate every derivative from the repository root:

```sh
python3 Scripts/generate-brand-assets.py --check
```
