# Test page templates

Reusable assets for building per-requirement test pages under `tests/reqXXX/`.

## Files

- [template.html](template.html) — standalone HTML page (no build step) with
  the Red Hat color palette, header/footer, scenario panel, controls panel and
  a structured on-screen log.

## Using the template

1. Copy `template.html` into the test folder:

   ```bash
   cp tests/templates/template.html tests/reqXXX/index.html
   ```

2. Edit the blocks marked `<!-- TEMPLATE: ... -->`:
   - page `<title>`
   - header label (e.g. `REQ 14`)
   - `<h1>` heading and subtitle
   - the `<pre class="scenario">` block (objective / ASCII diagram)
   - the inputs/buttons inside `#controls`
   - the script block at the bottom for custom logic

3. Use the helpers already wired in the page:
   - `logLine(message, level)` where `level` is `info`, `success`, `warn`, `error`
   - `clearLog()` to reset the log panel

## Running a test page

Most tests just need a static file server. Two easy options:

```bash
# Python (ships with macOS)
python3 -m http.server 8080 --directory tests/reqXXX

# Or Node
npx --yes serve tests/reqXXX -l 8080
```

Then open <http://localhost:8080>.

> Some tests (CORS, cookies, mixed content) only reproduce the real browser
> behavior when the page is served from a different origin than the backend.
> Opening `index.html` via `file://` will not trigger preflight requests the
> same way a real origin does.
