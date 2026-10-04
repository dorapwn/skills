---
name: headless-browser
description: Drive headless Chrome via browser-use for JS pages or interaction.
version: 0.1.0
author: Neoalienson, Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [browser, chrome, headless, cdp, scraping, automation]
    related_skills: []
---

# Headless Browser Skill

Drive a real headless Chromium via the `browser-use` CLI for tasks that need
JS rendering, user interaction, or to bypass basic bot detection. Pure HTTP
fetches are cheaper — only reach for the browser when a plain GET returns a
shell page, a JS-only app, or you need to click/type.

## Scope

Intended for **Hermes Agent running on the official Docker image only**. The
official image has everything baked in:

- `browser-use` CLI on PATH (uv tool, pre-installed).
- Google Chrome for Testing at
  `/opt/data/home/.agent-browser/browsers/chrome-*/chrome`.
- `/opt/data/cache/scratch/` as scratch location for the Chrome
  `--user-data-dir` and screenshots.

If you are NOT on the official image, install these yourself before using
this skill — `uv tool install browser-use` plus a Chrome for Testing binary
at the path above.

Do NOT run `playwright install` or `apt-get install chromium` on the
official image — they download a redundant browser and inflate the image.

## Usage

**1. Launch Chrome with remote debugging** (background, one-shot per session):

```bash
CHROME=/opt/data/home/.agent-browser/browsers/chrome-*/chrome
"$CHROME" \
  --headless=new --no-sandbox --disable-gpu \
  --remote-debugging-port=9222 --remote-debugging-address=127.0.0.1 \
  --user-data-dir=/opt/data/cache/scratch/chrome-data \
  --hide-scrollbars about:blank &
```

A dedicated `--user-data-dir` is required. Chrome locks the default profile
when CDP is enabled; a per-session dir avoids the M136/M144 "Allow remote
debugging" dialog and stale `DevToolsActivePort` files.

**2. Set `BU_CDP_URL`** so the daemon skips its default profile discovery and
attaches directly:

```bash
export BU_CDP_URL=http://127.0.0.1:9222
```

**3. Drive it.** First navigation is `new_tab(url)` (not `goto_url`) so the
daemon attaches to the tab across subsequent calls:

```bash
browser-use <<'PY'
new_tab("https://example.com")
print(page_info())               # url, title, viewport, scroll
print(js("document.title"))      # arbitrary JS evaluation
capture_screenshot(path="/opt/data/cache/scratch/out.png")
PY
```

## Helpers

| Helper | Purpose |
| --- | --- |
| `new_tab(url)` | Open + attach to a tab (use first, per task) |
| `goto_url(url)` | Navigate the attached tab |
| `page_info()` | URL, title, viewport, scroll position |
| `js(code)` | Evaluate JS in the page, return value |
| `capture_screenshot(path=...)` | PNG to disk |
| `click_at_xy(x, y)` / `type_text(text)` / `fill_input(sel, txt)` / `press_key(k)` | Input |
| `scroll(x, y)` | Scroll |
| `wait_for_load()` / `wait_for_element(sel)` | Sync |
| `list_tabs()` / `switch_tab(t)` / `close_tab(t)` | Tab management |

`browser-use skill show` lists the full interface.

## Pitfalls

- **Setting `BU_CDP_URL` is mandatory when you launch Chrome with a custom
  `--user-data-dir`.** The daemon's default discovery scans well-known
  profile dirs and misses yours, then fails with the misleading
  `chrome-not-running: no supported Chromium-family browser is running` —
  even when `/json/version` returns 200.
- **Reuse tabs.** `new_tab()` attaches; calling it again on the same task
  leaves duplicate tabs open. Inspect `list_tabs()` and `switch_tab()`
  before opening another.
- **Time everything.** Pass `timeout` to `goto_url`/`wait_for_element`. The
  default 30s is too generous for cron; 5–10S is usually right.
- **Block noise.** `page.route("**/*.{png,jpg,woff2}", r.abort)` (Playwright)
  or skip if using `js` — saves bandwidth and speeds up render.
- **Screenshot on failure.** `capture_screenshot(path=...)` inside an
  `except` is the highest-ROI debugging habit.

## Fallback Ladder

Before reaching for the browser, try:

1. `curl` / `web_extract` for static HTML.
2. Site's own `/api/`, `/graphql`, or `.json` endpoint.
3. Wayback Machine (`archive.org/wayback/available?url=`) or
   `archive.ph` for already-published blocked pages.
4. **Then** the headless browser.

## Verification

```bash
BU_CDP_URL=http://127.0.0.1:9222 browser-use doctor
# expect: [ok] chrome running
```
