#!/usr/bin/env python3

import argparse
import hashlib
import json
import math
import os
import random
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from collections import deque
from pathlib import Path

from PIL import Image


SIZE = 1024
OUTLINE = "#763424"
TERRACOTTA = "#A65136"
IVORY = "#F8F4EC"
SOURCE_CENTER = (541.5, 540.0)
OFFSET = (SIZE / 2 - SOURCE_CENTER[0], SIZE / 2 - SOURCE_CENTER[1])
EXPECTED_GEOMETRY_SHA256 = "d3f585bfad542d8e4e090919adf1110bc3d0d712436af801c2fa614623a6d04c"
OUTER_TRACE_PATHS = []
OUTER_TRACE_CENTER = None
APPROVED_SILHOUETTE_IOU = 0.0
OUTER_VERTEX_COUNT = 0

OUTER_RAYS_SOURCE = [
    [(224.5, 221.0), (453.0, 385.0), (473.0, 471.0), (387.0, 452.0)],
    [(542.3, 89.3), (587.5, 369.0), (541.5, 442.0), (495.0, 367.5)],
    [(858.3, 221.7), (696.7, 451.0), (609.5, 470.5), (629.3, 386.0)],
    [(991.5, 540.0), (710.7, 587.7), (640.0, 540.0), (714.5, 493.5)],
    [(856.7, 860.0), (629.7, 695.3), (610.0, 610.0), (697.3, 630.7)],
    [(541.0, 988.5), (495.5, 716.2), (541.0, 639.0), (588.0, 714.0)],
    [(227.0, 860.3), (386.3, 630.0), (473.0, 610.0), (451.3, 697.3)],
    [(91.7, 540.0), (369.5, 494.0), (442.7, 539.3), (372.7, 587.7)],
]

INNER_RAYS_SOURCE = [
    [(247.3, 243.3), (446.0, 389.0), (464.0, 462.0), (392.0, 445.7)],
    [(541.0, 118.0), (581.0, 366.5), (541.0, 430.7), (502.0, 366.5)],
    [(836.5, 242.0), (691.0, 445.7), (619.0, 462.0), (635.5, 389.5)],
    [(961.0, 540.0), (712.3, 579.7), (652.3, 540.0), (715.0, 501.0)],
    [(835.5, 838.0), (636.0, 692.0), (620.0, 620.0), (694.0, 638.3)],
    [(541.0, 961.0), (502.0, 717.0), (541.5, 651.0), (581.0, 714.5)],
    [(247.3, 837.7), (390.7, 636.0), (463.0, 619.0), (447.5, 691.5)],
    [(123.0, 540.0), (368.0, 501.0), (431.0, 540.5), (367.0, 579.5)],
]


def translated(points):
    return [(x + OFFSET[0], y + OFFSET[1]) for x, y in points]


OUTER_RAYS = [translated(points) for points in OUTER_RAYS_SOURCE]
INNER_RAYS = [translated(points) for points in INNER_RAYS_SOURCE]


def fmt(value):
    return f"{value:.4f}".rstrip("0").rstrip(".")


def polygon(points):
    return "M " + " L ".join(f"{fmt(x)} {fmt(y)}" for x, y in points) + " Z"


def ray_paths(rays, fill=None):
    attribute = f' fill="{fill}"' if fill else ""
    return "\n".join(f'<path d="{polygon(points)}"{attribute}/>' for points in rays)


def exact_outer_elements(fill=None):
    attribute = f' fill="{fill}"' if fill else ""
    if OUTER_TRACE_PATHS:
        paths = "\n".join(f'<path d="{path}"{attribute}/>' for path in OUTER_TRACE_PATHS)
        center = OUTER_TRACE_CENTER
        return (
            f"{paths}\n"
            f'<ellipse cx="{fmt(center["cx"])}" cy="{fmt(center["cy"])}" '
            f'rx="{fmt(center["rx"])}" ry="{fmt(center["ry"])}"{attribute}/>'
        )
    return (
        f"{ray_paths(OUTER_RAYS, fill)}\n"
        f'<ellipse cx="512" cy="512" rx="44.5" ry="45"{attribute}/>'
    )


def exact_inner_elements(fill=None):
    attribute = f' fill="{fill}"' if fill else ""
    return (
        f"{ray_paths(INNER_RAYS, fill)}\n"
        f'<ellipse cx="511.5" cy="512" rx="38" ry="38"{attribute}/>'
    )


def geometry_signature():
    payload = json.dumps(
        {
            "outer": OUTER_RAYS_SOURCE,
            "inner": INNER_RAYS_SOURCE,
            "outer_center": [541.5, 540.0, 44.5, 45.0],
            "inner_center": [541.0, 540.0, 38.0, 38.0],
            "reference_outline": OUTER_TRACE_PATHS,
            "reference_outline_center": OUTER_TRACE_CENTER,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(payload).hexdigest()


def texture_elements():
    generator = random.Random(31)
    circles = []
    for _ in range(220):
        x = generator.uniform(90, 934)
        y = generator.uniform(90, 934)
        radius = generator.uniform(0.8, 3.8)
        opacity = generator.uniform(0.018, 0.072)
        circles.append(
            f'<circle cx="{fmt(x)}" cy="{fmt(y)}" r="{fmt(radius)}" '
            f'fill="#3E1B14" opacity="{fmt(opacity)}"/>'
        )
    strokes = []
    for _ in range(44):
        x = generator.uniform(100, 900)
        y = generator.uniform(100, 900)
        length = generator.uniform(12, 46)
        angle = generator.uniform(0, math.tau)
        dx = math.cos(angle) * length
        dy = math.sin(angle) * length
        opacity = generator.uniform(0.012, 0.04)
        strokes.append(
            f'<path d="M {fmt(x)} {fmt(y)} l {fmt(dx)} {fmt(dy)}" '
            f'stroke="#4F2119" stroke-width="{fmt(generator.uniform(0.6, 1.5))}" '
            f'opacity="{fmt(opacity)}"/>'
        )
    return "\n".join(circles + strokes)


def exact_color_mark_svg(background=None, texture=True):
    backdrop = f'<rect width="1024" height="1024" fill="{background}"/>\n' if background else ""
    texture_layer = ""
    definitions = ""
    if texture:
        definitions = f'''<defs>
<clipPath id="terracotta-fill">
{exact_inner_elements()}
</clipPath>
</defs>
'''
        texture_layer = f'''<g clip-path="url(#terracotta-fill)">
{texture_elements()}
</g>
'''
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
{definitions}{backdrop}<g shape-rendering="geometricPrecision">
{exact_outer_elements(OUTLINE)}
{exact_inner_elements(TERRACOTTA)}
{texture_layer}</g>
</svg>
'''


def exact_monochrome_svg(fill):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<g fill="{fill}" shape-rendering="geometricPrecision">
{exact_outer_elements()}
</g>
</svg>
'''


def status_rays():
    result = []
    for ray in OUTER_RAYS:
        radii = [math.hypot(x - 512, y - 512) for x, y in ray]
        inner_index = min(range(len(ray)), key=radii.__getitem__)
        tip_index = max(range(len(ray)), key=radii.__getitem__)
        adjusted = []
        for index, (x, y) in enumerate(ray):
            dx = (x - 512) / 1024 * 14
            dy = (y - 512) / 1024 * 14
            radius = math.hypot(dx, dy)
            target = radius if index == tip_index else 2.7 if index == inner_index else 3.4
            scale = target / radius
            adjusted.append((7 + dx * scale, 7 + dy * scale))
        result.append(adjusted)
    return result


STATUS_RAYS = status_rays()


def status_elements(fill):
    return f'''<g fill="{fill}" shape-rendering="geometricPrecision">
{ray_paths(STATUS_RAYS)}
<circle cx="7" cy="7" r="0.9"/>
</g>'''


def status_svg(fill, background=None):
    backdrop = f'<rect width="14" height="14" fill="{background}"/>\n' if background else ""
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 14 14">
{backdrop}{status_elements(fill)}
</svg>
'''


def run(command, env=None, capture=False):
    completed = subprocess.run(
        [str(part) for part in command],
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        env=env,
    )
    return completed.stdout if capture else ""


def require_tool(name, alternatives=()):
    found = shutil.which(name)
    if found:
        return Path(found)
    for alternative in alternatives:
        candidate = Path(alternative)
        if candidate.is_file():
            return candidate
    raise RuntimeError(f"Required tool is unavailable: {name}")


def deterministic_environment():
    environment = os.environ.copy()
    environment["SOURCE_DATE_EPOCH"] = "0"
    environment["TZ"] = "UTC"
    return environment


def render_svg(converter, source, destination, width, height, background=None):
    command = [converter, "--width", str(width), "--height", str(height), "--output", destination]
    if background:
        command.extend(["--background-color", background])
    command.append(source)
    run(command, env=deterministic_environment())


def render_pdf(converter, source, destination, width, height):
    run(
        [
            converter,
            "--format=pdf",
            f"--width={width}pt",
            f"--height={height}pt",
            f"--page-width={width}pt",
            f"--page-height={height}pt",
            f"--output={destination}",
            source,
        ],
        env=deterministic_environment(),
    )


def write_text(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(payload, encoding="utf-8")


def copy_font(repo, source_directory):
    destination = source_directory / "LoftyGoals.otf"
    runtime_font = repo / "Sources/OmniWM/Resources/LoftyGoals.otf"
    if not destination.exists():
        if not runtime_font.is_file():
            raise RuntimeError("LoftyGoals.otf was not found in brand sources or runtime resources")
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(runtime_font, destination)
    return destination


def load_reference_outline(source_directory):
    path = source_directory / "omniwm-reference-outline.json"
    if not path.is_file():
        raise RuntimeError(f"Canonical reference outline is missing: {path}")
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("canvas") != [1024, 1024] or len(payload.get("paths", [])) != 8:
        raise RuntimeError("Canonical reference outline must contain eight ray paths on a 1024 square canvas")
    center = payload.get("center")
    if sorted(center or {}) != ["cx", "cy", "rx", "ry"]:
        raise RuntimeError("Canonical reference outline center is invalid")
    if payload.get("vertex-count") != 71 or payload.get("fit-tolerance-px") != 1.4:
        raise RuntimeError("Canonical reference outline fit metadata changed")
    return payload


def wordmark_paths(hb_view, font):
    with tempfile.TemporaryDirectory(prefix="omniwm-wordmark-") as raw:
        output = Path(raw) / "wordmark.svg"
        run(
            [
                hb_view,
                font,
                "OmniWM",
                "--font-size=1000",
                "--margin=0",
                "--background=none",
                "--foreground=000000",
                "--output-format=svg",
                f"--output-file={output}",
            ],
            env=deterministic_environment(),
        )
        root = ET.parse(output).getroot()
    namespace = "{http://www.w3.org/2000/svg}"
    xlink = "{http://www.w3.org/1999/xlink}href"
    definitions = {
        group.attrib["id"]: group.find(namespace + "path").attrib["d"]
        for group in root.findall(".//" + namespace + "g")
        if "id" in group.attrib and group.find(namespace + "path") is not None
    }
    paths = []
    for use in root.findall(".//" + namespace + "use"):
        identifier = use.attrib[xlink].removeprefix("#")
        paths.append(
            f'<path d="{definitions[identifier]}" transform="translate('
            f'{use.attrib.get("x", "0")} {use.attrib.get("y", "0")})"/>'
        )
    if len(paths) != len("OmniWM"):
        raise RuntimeError(f"Expected 6 wordmark glyph paths, found {len(paths)}")
    return "\n".join(paths)


def wordmark_svg(paths, fill):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="3701" height="1138" viewBox="0 0 3701 1138">
<g fill="{fill}" shape-rendering="geometricPrecision">
{paths}
</g>
</svg>
'''


def lockup_svg(paths, mark_fill, word_fill, textured=False):
    if mark_fill == "color":
        definitions = ""
        texture = ""
        if textured:
            definitions = f'''<defs>
<clipPath id="lockup-terracotta">
<g transform="translate(64 64) scale(0.875)">{exact_inner_elements()}</g>
</clipPath>
</defs>
'''
            texture = f'''<g clip-path="url(#lockup-terracotta)" transform="translate(64 64) scale(0.875)">
{texture_elements()}
</g>
'''
        mark = f'''<g transform="translate(64 64) scale(0.875)">
{exact_outer_elements(OUTLINE)}
{exact_inner_elements(TERRACOTTA)}
</g>
{texture}'''
    else:
        definitions = ""
        mark = f'''<g fill="{mark_fill}" transform="translate(64 64) scale(0.875)">
{exact_outer_elements()}
</g>'''
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="3200" height="1024" viewBox="0 0 3200 1024">
{definitions}{mark}
<g fill="{word_fill}" transform="translate(1050 199) scale(0.55)" shape-rendering="geometricPrecision">
{paths}
</g>
</svg>
'''


def app_layer_svg(elements, fill):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<g fill="{fill}" shape-rendering="geometricPrecision">
{elements}
</g>
</svg>
'''


def write_icon_composer_source(app_directory):
    package = app_directory / "AppIcon.icon"
    assets = package / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    write_text(assets / "01 Terracotta.svg", app_layer_svg(exact_inner_elements(), TERRACOTTA))
    write_text(assets / "02 Outline.svg", app_layer_svg(exact_outer_elements(), OUTLINE))
    manifest = {
        "fill": {"solid": "srgb:0.97255,0.95686,0.92549,1.00000"},
        "groups": [
            {
                "layers": [
                    {
                        "fill": "none",
                        "glass": False,
                        "image-name": "01 Terracotta.svg",
                        "name": "Terracotta",
                    },
                    {
                        "fill": "none",
                        "glass": False,
                        "image-name": "02 Outline.svg",
                        "name": "Outline",
                    },
                ],
                "shadow": {"kind": "neutral", "opacity": 0.12},
                "specular": False,
                "translucency": {"enabled": False, "value": 0},
            }
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }
    write_text(package / "icon.json", json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return package


def write_icns(converter, iconutil, app_svg, destination):
    representations = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }
    with tempfile.TemporaryDirectory(prefix="omniwm-iconset-") as raw:
        iconset = Path(raw) / "AppIcon.iconset"
        iconset.mkdir()
        for name, pixels in representations.items():
            render_svg(converter, app_svg, iconset / name, pixels, pixels)
        destination.parent.mkdir(parents=True, exist_ok=True)
        run([iconutil, "--convert", "icns", "--output", destination, iconset])


def alpha_components(path, threshold):
    alpha = Image.open(path).convert("RGBA").getchannel("A")
    active = {
        (x, y)
        for y in range(alpha.height)
        for x in range(alpha.width)
        if alpha.getpixel((x, y)) >= threshold
    }
    remaining = set(active)
    count = 0
    while remaining:
        count += 1
        queue = deque([remaining.pop()])
        while queue:
            x, y = queue.popleft()
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    neighbor = (x + dx, y + dy)
                    if neighbor in remaining:
                        remaining.remove(neighbor)
                        queue.append(neighbor)
    return count


def svg_audit(path):
    root = ET.parse(path).getroot()
    forbidden = {"text", "script", "image", "mask"}
    found = []
    for element in root.iter():
        local_name = element.tag.rsplit("}", 1)[-1]
        if local_name in forbidden:
            found.append(local_name)
    if found:
        raise RuntimeError(f"Forbidden SVG elements in {path}: {sorted(set(found))}")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def relative_hashes(repo, paths):
    return {str(path.relative_to(repo)): sha256(path) for path in sorted(paths)}


def write_readmes(brand_directory):
    brand_readme = f'''# OmniWM brand assets

The canonical geometry is the reference-faithful eight-ray mark in `source/omniwm-mark-color.svg`. Normal-size app, launch, and web assets use that geometry unchanged. The status and favicon silhouettes use the optical microcut in `source/omniwm-status-template.svg` so the center dot and all eight rays remain separate at 14 px.

## Palette

| Role | Hex |
| --- | --- |
| Terracotta | `{TERRACOTTA}` |
| Brown outline and wordmark | `{OUTLINE}` |
| Warm ivory | `{IVORY}` |

Use the color artwork for the app and website. Use the template PDF for native macOS interface placement; AppKit supplies black in light mode and white in dark mode. Do not add a baked rounded mask, recolor individual rays, add text inside the mark, or alter the center-dot separation.

Regenerate and validate every derivative from the repository root:

```sh
python3 Scripts/generate-brand-assets.py --check
```
'''
    web_readme = f'''# OmniWM web identity

Use `omniwm-logo.svg` for a webpage header and `omniwm-mark.svg` when a standalone mark fits better. Both SVGs have transparent backgrounds. Ivory-backed PNG fallbacks are supplied at 1× and 2×.

```html
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="icon" href="/favicon-32x32.png" sizes="32x32" type="image/png">
<link rel="icon" href="/favicon-16x16.png" sizes="16x16" type="image/png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png" sizes="180x180">
<link rel="mask-icon" href="/safari-pinned-tab.svg" color="{OUTLINE}">
<meta name="theme-color" content="{IVORY}">

<img src="/omniwm-logo.svg" alt="OmniWM">
```

Keep clear space equal to at least one center-dot diameter around the mark or lockup. Use the horizontal logo at 180 CSS px or wider; below that, use the standalone mark. The accessible name is `OmniWM`.
'''
    write_text(brand_directory / "README.md", brand_readme)
    write_text(brand_directory / "web/README.md", web_readme)


def generate(repo):
    global APPROVED_SILHOUETTE_IOU, OUTER_TRACE_CENTER, OUTER_TRACE_PATHS, OUTER_VERTEX_COUNT

    converter = require_tool("rsvg-convert", ("/opt/homebrew/bin/rsvg-convert",))
    hb_view = require_tool("hb-view", ("/opt/homebrew/bin/hb-view",))
    iconutil = require_tool("iconutil", ("/usr/bin/iconutil",))
    ictool = require_tool(
        "icon-composer-ictool",
        (
            "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool",
        ),
    )

    brand = repo / "assets/brand"
    source = brand / "source"
    app = brand / "app"
    status = brand / "status"
    launch = brand / "launch"
    web = brand / "web"
    for directory in (source, app, status, launch, web):
        directory.mkdir(parents=True, exist_ok=True)

    reference_outline = load_reference_outline(source)
    OUTER_TRACE_PATHS = reference_outline["paths"]
    OUTER_TRACE_CENTER = reference_outline["center"]
    APPROVED_SILHOUETTE_IOU = reference_outline["approved-silhouette-iou"]
    OUTER_VERTEX_COUNT = reference_outline["vertex-count"]
    font = copy_font(repo, source)
    glyph_paths = wordmark_paths(hb_view, font)
    exact_color = exact_color_mark_svg(texture=True)
    exact_ivory = exact_color_mark_svg(background=IVORY, texture=True)
    exact_black = exact_monochrome_svg("#000000")
    status_black = status_svg("#000000")
    status_white = status_svg("#FFFFFF")
    favicon = status_svg(TERRACOTTA, IVORY)
    wordmark = wordmark_svg(glyph_paths, OUTLINE)
    web_lockup = lockup_svg(glyph_paths, "color", OUTLINE, textured=True)
    launch_lockup = lockup_svg(glyph_paths, "#FFFFFF", "#FFFFFF")

    source_files = {
        source / "omniwm-mark-color.svg": exact_color,
        source / "omniwm-mark-color-ivory.svg": exact_ivory,
        source / "omniwm-mark-monochrome.svg": exact_black,
        source / "omniwm-status-template.svg": status_black,
        source / "omniwm-wordmark-outline.svg": wordmark,
        source / "omniwm-launch-lockup.svg": launch_lockup,
        app / "omniwm-app-icon.svg": exact_ivory,
        status / "omniwm-status-template.svg": status_black,
        launch / "omniwm-launch-lockup.svg": launch_lockup,
        web / "omniwm-mark.svg": exact_color,
        web / "omniwm-logo.svg": web_lockup,
        web / "favicon.svg": favicon,
        web / "safari-pinned-tab.svg": status_black,
    }
    for path, payload in source_files.items():
        write_text(path, payload)

    render_svg(converter, app / "omniwm-app-icon.svg", app / "omniwm-app-icon-1024.png", 1024, 1024)
    write_icns(converter, iconutil, app / "omniwm-app-icon.svg", repo / "Resources/AppIcon.icns")

    icon_package = write_icon_composer_source(app)
    with tempfile.TemporaryDirectory(prefix="omniwm-icon-composer-") as raw:
        preview = Path(raw) / "preview.png"
        run(
            [
                ictool,
                icon_package,
                "--export-image",
                "--output-file",
                preview,
                "--platform",
                "macOS",
                "--rendition",
                "Default",
                "--width",
                "1024",
                "--height",
                "1024",
                "--scale",
                "1",
            ],
            env=deterministic_environment(),
            capture=True,
        )
        if Image.open(preview).size != (1024, 1024):
            raise RuntimeError("Icon Composer preview has the wrong dimensions")

    proof_paths = []
    for color, payload in (("black", status_black), ("white", status_white)):
        temporary_svg = status / f"omniwm-status-{color}.svg"
        write_text(temporary_svg, payload)
        for points, scale in ((14, 1), (14, 2), (18, 1), (18, 2)):
            pixels = points * scale
            output = status / f"omniwm-status-{color}-{points}pt@{scale}x.png"
            render_svg(converter, temporary_svg, output, pixels, pixels)
            proof_paths.append(output)
        temporary_svg.unlink()

    runtime_status = repo / "Sources/OmniWM/Resources/OmniWMStatusTemplate.pdf"
    runtime_lockup = repo / "Sources/OmniWM/Resources/OmniWMLaunchLockup.pdf"
    render_pdf(converter, status / "omniwm-status-template.svg", runtime_status, 18, 18)
    render_pdf(converter, launch / "omniwm-launch-lockup.svg", runtime_lockup, 600, 192)

    render_svg(converter, web / "omniwm-mark.svg", web / "omniwm-mark-ivory@1x.png", 512, 512, IVORY)
    render_svg(converter, web / "omniwm-mark.svg", web / "omniwm-mark-ivory@2x.png", 1024, 1024, IVORY)
    render_svg(converter, web / "omniwm-logo.svg", web / "omniwm-logo-ivory@1x.png", 1600, 512, IVORY)
    render_svg(converter, web / "omniwm-logo.svg", web / "omniwm-logo-ivory@2x.png", 3200, 1024, IVORY)
    render_svg(converter, web / "favicon.svg", web / "favicon-16x16.png", 16, 16)
    render_svg(converter, web / "favicon.svg", web / "favicon-32x32.png", 32, 32)
    render_svg(converter, web / "favicon.svg", web / "apple-touch-icon.png", 180, 180)
    with tempfile.TemporaryDirectory(prefix="omniwm-favicon-") as raw:
        source_png = Path(raw) / "favicon-256.png"
        render_svg(converter, web / "favicon.svg", source_png, 256, 256)
        Image.open(source_png).convert("RGBA").save(
            web / "favicon.ico",
            format="ICO",
            sizes=[(16, 16), (32, 32), (48, 48)],
        )

    write_readmes(brand)
    tracked = [
        path
        for path in brand.rglob("*")
        if path.is_file() and path.name not in {"manifest.sha256", "validation-report.json"}
    ] + [repo / "Resources/AppIcon.icns", runtime_status, runtime_lockup]
    hashes = relative_hashes(repo, tracked)
    write_text(
        brand / "manifest.sha256",
        "".join(f"{digest}  {path}\n" for path, digest in sorted(hashes.items())),
    )
    return {
        "brand": brand,
        "converter": converter,
        "geometry_sha256": geometry_signature(),
        "hashes": hashes,
        "proof_paths": proof_paths,
        "runtime_status": runtime_status,
        "runtime_lockup": runtime_lockup,
        "web": web,
    }


def validate(repo, generated):
    brand = generated["brand"]
    converter = generated["converter"]
    geometry_hash = generated["geometry_sha256"]
    if geometry_hash != EXPECTED_GEOMETRY_SHA256:
        raise RuntimeError(
            f"Canonical geometry changed: expected {EXPECTED_GEOMETRY_SHA256}, found {geometry_hash}"
        )

    svg_paths = sorted(brand.rglob("*.svg"))
    for path in svg_paths:
        svg_audit(path)

    app_master = Image.open(brand / "app/omniwm-app-icon-1024.png").convert("RGBA")
    if app_master.size != (1024, 1024):
        raise RuntimeError("App icon master must be 1024 x 1024")
    if app_master.getchannel("A").getextrema() != (255, 255):
        raise RuntimeError("App icon master must be fully opaque")

    status_results = {}
    with tempfile.TemporaryDirectory(prefix="omniwm-status-validation-") as raw:
        temporary = Path(raw)
        black_svg = brand / "status/omniwm-status-template.svg"
        white_svg = temporary / "white.svg"
        write_text(white_svg, status_svg("#FFFFFF"))
        for pixels in (14, 16, 18, 28, 32, 36, 48):
            black_png = temporary / f"black-{pixels}.png"
            white_png = temporary / f"white-{pixels}.png"
            render_svg(converter, black_svg, black_png, pixels, pixels)
            render_svg(converter, white_svg, white_png, pixels, pixels)
            black_alpha = Image.open(black_png).convert("RGBA").getchannel("A").tobytes()
            white_alpha = Image.open(white_png).convert("RGBA").getchannel("A").tobytes()
            if black_alpha != white_alpha:
                raise RuntimeError(f"Black and white status alpha differ at {pixels} px")
            threshold_results = {
                str(threshold): alpha_components(black_png, threshold) for threshold in (64, 128)
            }
            if set(threshold_results.values()) != {9}:
                raise RuntimeError(
                    f"Status cut has merged or missing components at {pixels} px: {threshold_results}"
                )
            status_results[str(pixels)] = threshold_results

    expected_dimensions = {
        "favicon-16x16.png": (16, 16),
        "favicon-32x32.png": (32, 32),
        "apple-touch-icon.png": (180, 180),
        "omniwm-mark-ivory@1x.png": (512, 512),
        "omniwm-mark-ivory@2x.png": (1024, 1024),
        "omniwm-logo-ivory@1x.png": (1600, 512),
        "omniwm-logo-ivory@2x.png": (3200, 1024),
    }
    for name, dimensions in expected_dimensions.items():
        actual = Image.open(generated["web"] / name).size
        if actual != dimensions:
            raise RuntimeError(f"{name} has dimensions {actual}, expected {dimensions}")

    ico = Image.open(generated["web"] / "favicon.ico")
    ico_sizes = sorted([list(size) for size in ico.info.get("sizes", set())])
    if ico_sizes != [[16, 16], [32, 32], [48, 48]]:
        raise RuntimeError(f"ICO representations are wrong: {ico_sizes}")

    report = {
        "black_white_status_alpha_identical": True,
        "approved_silhouette_iou": APPROVED_SILHOUETTE_IOU,
        "canonical_geometry_sha256": geometry_hash,
        "favicon_ico_sizes": ico_sizes,
        "generated_hashes": generated["hashes"],
        "palette": {"ivory": IVORY, "outline": OUTLINE, "terracotta": TERRACOTTA},
        "status_components": status_results,
        "smooth_outer_vertex_count": OUTER_VERTEX_COUNT,
        "svg_files_audited": len(svg_paths),
        "validated": True,
    }
    write_text(
        brand / "validation-report.json",
        json.dumps(report, indent=2, sort_keys=True) + "\n",
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    generated = generate(repo)
    validate(repo, generated)
    if arguments.check:
        print(json.dumps({"validated": True, "files": len(generated["hashes"])}, sort_keys=True))


if __name__ == "__main__":
    main()
