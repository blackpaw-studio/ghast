# Ghast redesign mockups: shared kit

Ghast is a macOS app that turns a Mac into GitHub Actions self-hosted runners: sign in with GitHub (Device Flow), create a runner for a repository or organization (Ghast downloads, registers and runs the official runner), start/stop it, watch its live output, edit its env vars and pre/post-job scripts. It also lists runners registered on GitHub that live on other machines (status only).

Target look: **macOS 26 "Tahoe" (Liquid Glass)**, light by default, dark via a tweak. Calm, precise, Mac-native, like Apple's own apps (Mail, System Settings, Activity Monitor, Xcode). It must NOT look like a web dashboard: no stat-card grids, no gradients on controls, no colored backgrounds except status dots, the primary action and selection. Hierarchy comes from layout, spacing and type weight. Generous whitespace, nothing cramped.

## File format (Design canvas `.dc.html`, one file per artboard)

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>SHORT SCREEN NAME</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&amp;family=JetBrains+Mono:wght@400;500&amp;display=swap">
<style>
/* paste the TOKENS block below verbatim, then only small shared classes */
</style>
</helmet>
<div class="mock {{theme}}" style="position: relative; width: 1440px; height: 900px; overflow: hidden; background: var(--desk); font-family: var(--font); color: var(--label); -webkit-font-smoothing: antialiased">
  ... artboard ...
</div>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{"dark":{"editor":"boolean","default":false,"section":"Appearance"},"$preview":{"width":1440,"height":900}}'>
class Component extends DCLogic {
  renderVals() { return { theme: this.props.dark ? 'dark' : 'light' }; }
}
</script>
</body>
</html>
```

Rules (each one fails silently if broken):
- Keep `<script src="./support.js"></script>` exactly. Close every non-void element; quote every attribute.
- `{{theme}}` on the root is the ONLY hole. No `<sc-for>`/`<sc-if>`; write every row out as literal markup. All copy is literal text.
- Layout and styling inline (`style="…"`) using `var(--token)`. `<helmet><style>` holds only the tokens and a few shared classes (`.glass`, `.tok`, `.dot-*`, `.btn`, `.btn-primary`).
- Real `<button>`, `<input>`, `<label>`; `aria-label` on icon-only buttons; decorative SVG `aria-hidden="true"`. No `role`/onclick on divs. No emoji. No `<iframe>`, no images, no external assets beyond the Google Fonts link.
- Icons: inline SVG drawn like SF Symbols: `viewBox="0 0 16 16"`, `width/height 16` (sidebar/toolbar), `fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"`; play/stop/dots may be filled. Keep them simple and consistent.
- Text contrast ≥4.5:1: use `--label` or `--label-2` for text, never `--label-3` (non-text only).

## TOKENS (paste verbatim into `<helmet><style>`)

```css
body{margin:0}
.mock{
  --font:-apple-system,BlinkMacSystemFont,"SF Pro Text","Inter",system-ui,sans-serif;
  --mono:"SF Mono",ui-monospace,Menlo,"JetBrains Mono",monospace;
  --desk:linear-gradient(180deg,#dde3ec 0%,#cbd3df 100%);
  --win:#ffffff; --win-2:#f6f6f8; --group:#f3f3f5;
  --label:#1d1d1f; --label-2:#6e6e73; --label-3:#b4b4b9;
  --sep:rgba(0,0,0,.09); --fill:rgba(0,0,0,.05); --sel:rgba(0,0,0,.07);
  --accent-fill:#0071e3; --accent-ink:#0066cc; --accent-soft:rgba(0,113,227,.12);
  --green:#34c759; --orange:#ff9500; --red:#ff3b30;
  --glass:rgba(255,255,255,.72); --glass-border:rgba(0,0,0,.08); --glass-hi:rgba(255,255,255,.95);
  --glass-shadow:0 1px 2px rgba(0,0,0,.05),0 6px 16px rgba(0,0,0,.07);
  --sidebar:rgba(238,239,243,.86); --menu:rgba(246,246,248,.88);
  --win-shadow:0 0 0 .5px rgba(0,0,0,.16),0 24px 70px rgba(0,0,0,.20),0 6px 18px rgba(0,0,0,.08);
  --field:#ffffff; --field-border:rgba(0,0,0,.14); --knob:#ffffff; --track-off:rgba(0,0,0,.12);
  --scrim:rgba(0,0,0,.18);
}
.mock.dark{
  --desk:linear-gradient(180deg,#232730 0%,#14171d 100%);
  --win:#1e1e20; --win-2:#262628; --group:#2a2a2d;
  --label:rgba(255,255,255,.92); --label-2:#a1a1a6; --label-3:#5a5a5f;
  --sep:rgba(255,255,255,.10); --fill:rgba(255,255,255,.08); --sel:rgba(255,255,255,.10);
  --accent-fill:#0a6fdc; --accent-ink:#4da3ff; --accent-soft:rgba(77,163,255,.16);
  --green:#30d158; --orange:#ff9f0a; --red:#ff453a;
  --glass:rgba(52,52,56,.62); --glass-border:rgba(255,255,255,.10); --glass-hi:rgba(255,255,255,.12);
  --glass-shadow:0 1px 2px rgba(0,0,0,.3),0 6px 16px rgba(0,0,0,.3);
  --sidebar:rgba(40,40,44,.80); --menu:rgba(42,42,46,.86);
  --win-shadow:0 0 0 .5px rgba(255,255,255,.12),0 24px 70px rgba(0,0,0,.55);
  --field:rgba(255,255,255,.06); --field-border:rgba(255,255,255,.14); --knob:#e8e8ea; --track-off:rgba(255,255,255,.16);
  --scrim:rgba(0,0,0,.35);
}
.glass{background:var(--glass);-webkit-backdrop-filter:blur(24px) saturate(1.8);backdrop-filter:blur(24px) saturate(1.8);border:.5px solid var(--glass-border);box-shadow:inset 0 .5px 0 var(--glass-hi),var(--glass-shadow)}
```

## Window chrome (main windows)

- Window: `position:absolute; left:100px; top:60px; width:1240px; height:780px; border-radius:26px; background:var(--win); box-shadow:var(--win-shadow); overflow:hidden`.
- Sidebar: floating glass panel, `position:absolute; top:8px; left:8px; bottom:8px; width:248px; border-radius:18px; background:var(--sidebar)` plus the glass border/inset highlight/shadow. Padding 0 10px.
  - Traffic lights inside the sidebar, centered at window y=32: three 12px circles, 8px apart, first at window x=22. Colors `#ff5f57 #febc2e #28c840`, each `box-shadow: inset 0 0 0 .5px rgba(0,0,0,.15)`.
  - Sidebar-toggle icon button (sidebar.left glyph), 28×28, `--label-2`, top-right of the sidebar, centered at y=32.
  - Sidebar list starts at y≈60.
- Toolbar (no background; floats over content): spans x 264→1240, items vertically centered at y=32.
  - Leading: window title 15px/18px weight 600 + subtitle 11px/14px `--label-2` stacked. Title is the selection's name, never "Ghast".
  - Center (optional): segmented control.
  - Trailing: up to 3 groups, 8px apart. Group = `.glass` capsule, height 34px, radius 17px, padding 0 3px, holding icon buttons 30×30 (radius 15, glyph 16px, color `--label`). Text button inside a capsule: padding 0 12px, 13px weight 500.
  - Prominent action (at most one): same capsule but `background:var(--accent-fill); color:#fff; border:none`.
  - Segmented control: `.glass` capsule height 34, padding 3px; segments height 28, radius 14, padding 0 14px, 13px weight 500; selected segment `background:var(--win); box-shadow:0 1px 2px rgba(0,0,0,.12)` (dark: `background:rgba(255,255,255,.14)`).
- Content layer starts under the toolbar (content padding-top ≈ 64px). Content is plain window background, not glass.

## Components

- Sidebar section header: 11px weight 600 `--label-2`, padding 14px 8px 4px. Title case, not uppercase.
- Sidebar row: height 30px, radius 9px, padding 0 8px, gap 8px, 13px. Icon 16px in `--accent-ink`. Trailing count 12px `--label-2`. Selected: `background:var(--sel)`.
- Two-line sidebar row (runners): padding 7px 8px, radius 10px; status dot (8px) leading; name 13px weight 500; subtitle 11px `--label-2`.
- Status (one meaning per color; ALWAYS paired with words):
  - Idle (connected, waiting for jobs): filled `--green` dot.
  - Running a job: filled `--orange` dot with a 3px halo `box-shadow:0 0 0 3px rgba(255,149,0,.22)`.
  - Error (exited unexpectedly): filled `--red` dot.
  - Stopped / Offline: hollow ring, `border:1.5px solid var(--label-3)`, transparent fill.
- Runner label token `.tok`: inline-flex, height 20px, padding 0 7px, radius 6px, `background:var(--fill)`, 11px weight 500, `--label-2`.
- Push button `.btn`: height 28px, radius 999px, padding 0 14px, 13px weight 500, `background:var(--fill); border:.5px solid var(--sep); color:var(--label)`. `.btn-primary`: `background:var(--accent-fill); color:#fff; border:none`. Large (welcome): height 36px, 15px, padding 0 22px.
- Grouped form (System Settings style): box `background:var(--group); border-radius:12px`; rows min-height 40px, padding 0 14px, label left (13px), value/control right; 1px `--sep` separators inset 14px from the left. Group caption above: 11px weight 600 `--label-2`, padding 0 14px 6px. Help text below: 11px `--label-2`.
- Switch: 38×22, radius 11; on = `--accent-fill`; off = `--track-off`; white knob 18px with `box-shadow:0 1px 2px rgba(0,0,0,.25)`.
- Text field: height 28, radius 7, `background:var(--field); border:.5px solid var(--field-border)`, 13px, padding 0 8px. Focused field: add `box-shadow:0 0 0 3px var(--accent-soft)` and accent border.
- Table (Monitor only): header row 28px, 11px weight 600 `--label-2`, sort chevron on the sorted column; body rows 28px, 13px; zebra `background:var(--win-2)` on odd rows; selected row `background:var(--accent-fill); color:#fff` (its secondary text white at .8).
- Output / log text: `--mono` 12px/19px. Time column 64px wide in `--label-2`. Job-start lines get a small orange play glyph before the text; "completed … Succeeded" a green checkmark-circle glyph; "Failed" a red x-circle glyph; "Connected" a green checkmark. Other lines plain `--label`.
- Typography (macOS text styles): Large Title 26/32 bold · Title 1 22/26 bold · Title 2 17/22 weight 600 · Title 3 15/20 weight 600 · Headline 13/16 weight 600 · Body 13/16 · Callout 12/15 · Subheadline 11/14 · Footnote 10/13. Nothing below 10px.

## Sample data (use exactly, everywhere)

This Mac is named **Dionysus**. Now is **Monday, Nov 16, 10:12 AM**. Account: **Evan Coleman**, initials EC. Organization: **blackpaw-studio**. Repository: **blackpaw-studio/ghast**.

| Runner | Scope | Machine | Status | Labels |
|---|---|---|---|---|
| dionysus-arm64 | blackpaw-studio (org) | This Mac | Idle | self-hosted, macOS, ARM64 |
| dionysus-xcode | blackpaw-studio (org) | This Mac | Running job build-and-notarize, started 4 min ago | self-hosted, macOS, ARM64, xcode |
| ghast-release | blackpaw-studio/ghast (repo) | This Mac | Error: exited with code 1 at 10:05 AM | self-hosted, macOS, ARM64 |
| helios-linux | blackpaw-studio (org) | Other machine | Idle | self-hosted, Linux, X64 |
| iris-gpu | blackpaw-studio (org) | Other machine | Offline | self-hosted, Linux, X64, gpu |

dionysus-xcode: up 3 h 14 min, 5 jobs today, runner version 2.329.0, folder `~/.ghast/runners/dionysus-xcode`. Its output:

```
06:58:02  √ Connected to GitHub
06:58:02  Current runner version: '2.329.0'
06:58:03  Listening for Jobs
07:41:09  Running job: test
07:47:12  Job test completed with result: Succeeded
07:47:13  Listening for Jobs
08:15:40  Running job: build-and-notarize
08:27:20  Job build-and-notarize completed with result: Failed
08:27:21  Listening for Jobs
09:12:03  Running job: test
09:18:01  Job test completed with result: Succeeded
09:18:02  Listening for Jobs
10:01:12  Running job: lint
10:02:24  Job lint completed with result: Succeeded
10:02:25  Listening for Jobs
10:08:15  Running job: build-and-notarize
```

dionysus-arm64 recent jobs: test · Succeeded · 9:52 AM · 5m 48s / lint · Succeeded · 9:31 AM · 1m 09s / test · Failed · 8:40 AM · 4m 02s / test · Succeeded · Yesterday · 5m 51s. Up 3 h 14 min, version 2.329.0, folder `~/.ghast/runners/dionysus-arm64`, 2 environment variables, pre-job script on, post-job script off.

## Artboards (each 1440×900, desktop backdrop `var(--desk)`)

### Main.dc.html: 1 · Focus (recommended)
Two columns, like System Settings › Network. Runners themselves are the sidebar.
- Sidebar: section "This Mac": two-line runner rows dionysus-arm64 ("Idle · blackpaw-studio"), **dionysus-xcode selected** ("Running build-and-notarize"), ghast-release ("Exited with code 1"). Section "Other Machines": helios-linux ("Idle · blackpaw-studio"), iris-gpu ("Offline · blackpaw-studio").
- Toolbar: title "dionysus-xcode", subtitle "blackpaw-studio · This Mac". Center: segmented control "Output | Configuration" (Output selected). Trailing: capsule [stop.fill "Stop"] [arrow.clockwise "Restart"] as icon buttons; capsule [plus "New Runner"].
- Content (padding 0 32px): status header: orange-halo dot + "Running a job" (Title 2), below it "build-and-notarize · started 4 min ago" (Body, `--label-2`). Right side of the header: three small label/value stacks (Subheadline label over Body value): Uptime "3 h 14 min", Jobs Today "5", Version "2.329.0". Under the header: label tokens. Then a full-width 1px separator, then an "Output" row (Headline) with trailing borderless icon buttons: Follow (arrow.down.to.line, `--accent-ink`, active), Find (magnifyingglass), Copy (doc.on.doc), Clear (trash). Then the log lines filling the rest; the last line (job start) is the live one.

### Library.dc.html: 2 · Library
Three columns, like Mail: scopes › runners › detail.
- Sidebar: section "Runners": All Runners 5 (square.stack glyph, **selected**), This Mac 3 (laptop), Other Machines 2 (server rack), Needs Attention 1 (exclamationmark.triangle). Section "Organizations": blackpaw-studio 4 (building glyph). Section "Repositories": ghast 1 (book glyph).
- Middle list column (x 264→584, own right 1px `--sep` border, content layer): header "All Runners" (Headline) + "5 runners" (Subheadline) and a small sort button; then five two-line rows (status dot, name 13/500, subtitle "Idle · This Mac" etc., trailing tokens hidden), **dionysus-arm64 selected** (`--sel`, radius 10, inset 8px).
- Toolbar spans the detail column only (x 584→1240): title "dionysus-arm64", subtitle "blackpaw-studio". Trailing capsule [stop.fill][arrow.clockwise], capsule [terminal "Show Output"][ellipsis], capsule [plus].
- Detail (padding 0 32px, scrolls): header: 44px rounded-square tile (`--fill`, laptop glyph 22px) + name (Title 1) + status line (green dot "Idle, waiting for jobs"). Grouped section "Details": Scope "blackpaw-studio · Organization"; Machine "This Mac (Dionysus)"; Labels (tokens); Version "2.329.0"; Folder "~/.ghast/runners/dionysus-arm64" + small "Show in Finder" `.btn`. Grouped section "Recent Jobs": four rows from the sample (status glyph, job name, time `--label-2`, duration right-aligned). Grouped section "Configuration": Environment Variables "2" with chevron; Pre-Job Script "On" chevron; Post-Job Script "Off" chevron.

### Monitor.dc.html: 3 · Monitor
Dense, like Activity Monitor + Xcode's debug area.
- Sidebar: section "Show": All Runners 5 (**selected**), This Mac 3, Other Machines 2, Needs Attention 1. Section "Scopes": blackpaw-studio 4, ghast 1.
- Toolbar: title "All Runners", subtitle "5 runners · 1 busy". Center: capsule [play.fill "Start"][stop.fill "Stop"][arrow.clockwise "Restart"]. Trailing: glass search capsule (magnifyingglass + "Search" placeholder, width 180), capsule [plus].
- Content: top ~55%: Table, columns: Status (dot + word) | Name | Current Job | Scope | Machine | Labels | Uptime. Rows for all five runners (sorted: Running, Error, Idle, Idle, Offline); **dionysus-xcode selected**. Then a draggable 1px horizontal divider, then the output pane: header row "Output — dionysus-xcode" (Headline) + trailing Follow/Find/Copy/Clear icon buttons, then the log (last ~9 lines).

### Welcome.dc.html: Sign in
Two compact windows side by side on the desktop, each 560×520, radius 26, `var(--win)`, `var(--win-shadow)`, traffic lights at (22, 22), no sidebar, no toolbar. Left at x=120, right at x=760, top=190.
- Left "Welcome": centered column. 96px app icon (squircle radius 22px; light: `#ffffff→#eef0f4` surface with .5px border and soft shadow; a simple, friendly ghost glyph in `--label`, 52px; dark: `#3a3a3e→#2a2a2d`). "Welcome to Ghast" (Large Title). "Run GitHub Actions jobs on this Mac." (Title 3 weight 400, `--label-2`). Three feature rows, left-aligned in a 380px column (32px accent-ink glyph + Headline + Callout `--label-2`): "Your Mac, your runners": "Ghast downloads, registers and runs the official GitHub runner." / "Live output": "Watch each job as it runs, with status at a glance." / "Stays out of the way": "Runners keep working from the menu bar." Large `.btn-primary` "Sign In with GitHub". Footnote `--label-2`: "Ghast asks for access to your repositories and organization runners."
- Right "Device code": key glyph 32px `--accent-ink`. "Enter This Code on GitHub" (Title 1). Body `--label-2`, max 400px, centered: "Ghast opened github.com/login/device in your browser. Enter this code there to finish signing in." Code box: "WDJB-MJHT", `--mono` 34px weight 600, letter-spacing .08em, `background:var(--win-2)`, radius 12, padding 16px 28px. Buttons: `.btn` "Copy Code", `.btn-primary` "Open GitHub". Status line: small spinner (12 short radial ticks or a ring) + "Waiting for you to approve…" (Callout `--label-2`). `.btn` "Cancel".

### FirstRun.dc.html: First run, no runners yet
The Focus window (same chrome as Main) right after sign-in.
- Sidebar: section "This Mac" containing one muted row "No runners yet" (12px `--label-2`, no dot). Section "Other Machines": helios-linux, iris-gpu rows as in Main. Nothing selected except a "This Mac" header context.
- Toolbar: title "This Mac", subtitle "Dionysus". Trailing capsule [plus].
- Content: empty state centered in the content area: 56px glyph (laptop with a small plus, `--label-2`), "No Runners on This Mac" (Title 1), Body `--label-2`, max 380px, centered: "Create a runner for a repository or organization. Ghast downloads the official GitHub runner, registers it, and starts it for you." `.btn-primary` "New Runner…" and below it a plain accent-ink text button "About Self-Hosted Runners".

### NewRunner.dc.html: New Runner sheet
The Focus window (Main's chrome, simplified content is fine) under a `var(--scrim)` overlay, with TWO sheets side by side showing two states. Sheets: 500 wide, radius 22, `var(--win)`, `var(--win-shadow)`, padding 24px. Left sheet x=170 top=130; right sheet x=770 top=130.
- Left "Configure": "New Runner" (Title 2) + Body `--label-2`: "Ghast downloads the GitHub Actions runner, registers it, and starts it on this Mac." Grouped form: row "Add to": popup button showing a 16px org avatar circle + "blackpaw-studio" + `--label-2` "Organization" + up/down chevrons; row "Name": focused text field "dionysus-3"; row "Labels": token field holding self-hosted, macOS, ARM64 (fixed, `.tok`) + "xcode" token with a small ×, then placeholder "Add Label" in `--label-2`. Help text: "Names must be unique in blackpaw-studio. Default labels are added for you." A collapsed disclosure row: chevron.right + "Advanced" (13px) + `--label-2` "Architecture, runner group, work folder". Footer right-aligned: `.btn` "Cancel", `.btn-primary` "Create Runner".
- Right "Setting up": "Setting Up dionysus-3" (Title 2). Steps list (grouped box, rows 44px): green checkmark-circle "Download runner 2.329.0" trailing "182 MB"; green checkmark-circle "Register with blackpaw-studio"; spinner "Start runner" trailing "Connecting to GitHub…"; hollow circle `--label-3` "Listen for jobs". Footer: `.btn` "Cancel", disabled `.btn-primary` "Done" (opacity .45).

### Settings.dc.html: Settings window (⌘,)
Two Settings windows side by side, each 620×660, radius 26, top=120, left x=60 and x=760. Each: traffic lights at (22, 26); a toolbar row 64px tall with two centered tab items (glyph 20px over label 11px weight 500): "General" (gearshape) and "Account" (person.crop.circle). The selected tab has `background:var(--sel)` radius 8 and `--accent-ink` glyph. Window title not shown separately. Content padding 20px 28px, grouped form sections.
- Left, General selected. Group "Startup": "Open Ghast at login" (switch on); "Restart runners that were running when Ghast quit" (switch on). Group "Menu Bar & Notifications": "Show Ghast in the menu bar" (on); "Notify when a runner stops unexpectedly" (on); "Notify when a job fails" (off). Group "Updates": "Check for updates automatically" (on); row "Ghast 1.1.0 (2)" with `.btn` "Check Now". Group "Runners": "Runners folder" value "~/.ghast/runners" (`--label-2`, mono 12px) + `.btn` "Show in Finder".
- Right, Account selected. Centered: 64px circle avatar (`--accent-soft` fill, "EC" `--accent-ink` 24px weight 600), "Evan Coleman" (Title 2), "Signed in to GitHub" (Callout `--label-2`). Group "Permissions": "Repositories" trailing green checkmark + "Granted"; "Organization runners" trailing green checkmark + "Granted". Group "Organizations You Administer": row with 16px avatar + "blackpaw-studio". `.btn` "Sign Out…" left-aligned under the groups, with help text "Signing out doesn't stop or remove runners on this Mac."

### MenuBar.dc.html: Menu bar extra + notification
Desktop only (no Ghast window: the app is in the background).
- Menu bar strip across the top: height 26px, `background:rgba(255,255,255,.35)` (dark: `rgba(0,0,0,.25)`) with blur. Left: "Finder" (13px weight 700), then File Edit View Go Window Help (13px). Right, from x≈740: the Ghast extra (a monochrome 16px ghost glyph, shown pressed with a `--sel`-like rounded rect 26×22), then a Wi-Fi glyph, a control-center glyph, then "Mon Nov 16  10:12 AM" (13px). No Apple logo.
- Menu dropping from the ghost at x≈748, top 30, width 300: Tahoe menu (radius 12, `var(--menu)`, blur, .5px border, `--win-shadow`), padding 5px. Items 13px, height 24, padding 0 10px, radius 6. Content: section label "This Mac" (11px weight 600 `--label-2`); "● dionysus-arm64" + trailing `--label-2` "Idle" + chevron.right; "● dionysus-xcode" + "Running" + chevron.right, **highlighted** (`--accent-fill` bg, white text); "● ghast-release" + "Stopped" in red-dot form + chevron.right; separator; "Start All Runners"; "Stop All Runners"; separator; "New Runner…"; "Open Ghast"; separator; "Settings…" + trailing "⌘," ; "Quit Ghast" + trailing "⌘Q".
- Submenu open to the right of the highlighted item (width 180): "Show Output"; separator; "Restart"; "Stop".
- Notification banner top-right: x=1060, top=38, width 360, radius 18, `.glass` (use `var(--menu)` as its background), padding 12px 14px: 32px app icon (same squircle + ghost as Welcome, scaled) left; "Ghast" (11px weight 600 `--label-2`) with trailing "now"; title "ghast-release stopped unexpectedly" (13px weight 600); body "The runner exited with code 1. Click to see its output." (13px).
