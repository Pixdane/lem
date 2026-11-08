# how to customize

## font
```lisp
(set-font :name "Ubuntu Sans Mono" :size 19)
```

## background transparency and backdrop blur

`set-backdrop` controls how much of the desktop shows through the editor
window. All layers are applied at redraw time and glyphs always stay fully
opaque.

```lisp
(set-backdrop :opacity 0.85       ; whole-window tint, 1.0 = fully opaque
              :cell-opacity nil   ; nil = derive from opacity (opacity * 0.85, min 0.5)
              :popup-opacity 0.92 ; floating windows only
              :blur 24)           ; native Gaussian blur radius in pixels
```

Omitted keywords keep their current values. Frontends that do not support the
feature ignore the call; the default `lem-if:set-backdrop` method is a no-op,
so it is safe to put this in `init.lisp` for every frontend.

| keyword | affects |
| --- | --- |
| `:opacity` | the whole editor surface: the window tint, and through it the desktop |
| `:cell-opacity` | cell backgrounds that differ from the theme background (region, highlight-line, gutters, modeline). `nil` derives it from `:opacity` |
| `:popup-opacity` | floating windows only - compile/typeout notices and other floating frames. Sidebars and ordinary splits (REPL, help, compilation buffer, errors) follow `:opacity`, not `:popup-opacity` |
| `:blur` | native Gaussian blur radius behind the window, in pixels (macOS only) |

`M-x backdrop-opacity-set` (0-100) and `M-x backdrop-blur-set` (px) call
`set-backdrop` for you. Evaluate `set-backdrop` again (for example, with
`C-c C-c` in Lisp mode) to retune the effect without restarting.

### frontend support

- **webview (macOS)**: full support. The `NSWindow` is made non-opaque, the
  `WKWebView` background is cleared, and
  `CGSSetWindowBackgroundBlurRadius` from the private
  `SkyLight.framework` provides the Gaussian blur; WKWebView transparency is
  driven through the private `drawsBackground` key (KVC). Both are
  undocumented APIs that Apple can change between macOS releases, so treat a
  macOS upgrade as a possible breaking change. The native side is dispatched
  to the main thread through GCD and is only applied while the webview
  window exists - native calls made before it is created are ignored.
  Use sequential updates; simultaneous calls from different threads are not
  serialized.
- **server in a browser**: the opacity, cell and popup layers are plain CSS
  and work in any browser window; `:blur` is a no-op there. The only blur is
  the fixed 8px `backdrop-filter` that `editor.css` puts on bordered
  floating windows.
- **ncurses**: `:opacity` below 1.0 clears the terminal's default background
  so the terminal emulator's own transparency shows through. `:blur`,
  `:cell-opacity` and `:popup-opacity` are ignored, and whether anything is
  visible depends on the terminal emulator.
- **sdl2 / pdcurses**: no effect (default no-op method).

## floating window

This is a temporary API and is likely to change in the future.

```lisp
(lem-server::load-css ".lem-editor__floating-window--bordered {
  all: unset;
  border: 1px solid white;
  background-color: white;
}")
```
