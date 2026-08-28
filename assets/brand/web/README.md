# OmniWM web identity

Use `omniwm-logo.svg` for a webpage header and `omniwm-mark.svg` when a standalone mark fits better. Both SVGs have transparent backgrounds. Ivory-backed PNG fallbacks are supplied at 1× and 2×.

```html
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="icon" href="/favicon-32x32.png" sizes="32x32" type="image/png">
<link rel="icon" href="/favicon-16x16.png" sizes="16x16" type="image/png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png" sizes="180x180">
<link rel="mask-icon" href="/safari-pinned-tab.svg" color="#763424">
<meta name="theme-color" content="#F8F4EC">

<img src="/omniwm-logo.svg" alt="OmniWM">
```

Keep clear space equal to at least one center-dot diameter around the mark or lockup. Use the horizontal logo at 180 CSS px or wider; below that, use the standalone mark. The accessible name is `OmniWM`.
