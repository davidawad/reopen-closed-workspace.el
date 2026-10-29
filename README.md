# reopen-closed-workspace

A browser's "reopen closed tab", for Emacs workspaces. Close a tab-bar
tab or kill a persp-mode perspective and get it back as it was: its
name, its level (tab group), its place in the order, its window layout,
the files it showed, its terminals running their commands, and its
Claude Code sessions, resumed by id.

It is a thin shell over
[terra-emacs](https://github.com/davidawad/terra-emacs.el) and
[terra-emacs-capture](https://github.com/davidawad/terra-emacs-capture.el).
Just before a workspace closes, terra-emacs-capture captures its state;
reopening applies that state through the engine as a partial state, so
nothing else changes. Its companion,
[reopen-closed-buffer](https://github.com/davidawad/reopen-closed-buffer.el),
does the same for single buffers, and `reopen-closed-last` reopens
whichever closed last.

Pure Emacs Lisp, Emacs 29.1 or later. persp-mode is used when it is the
terra-emacs backend in use; otherwise workspaces are tab-bar tabs.

## Install

Emacs 30 and later, with `package-vc` (dependencies first):

```elisp
(package-vc-install "https://github.com/davidawad/terra-emacs.el")
(package-vc-install "https://github.com/davidawad/terra-emacs-capture.el")
(package-vc-install "https://github.com/davidawad/reopen-closed-workspace.el")
(require 'reopen-closed-workspace)
(reopen-closed-workspace-mode 1)
;; Optional, for `reopen-closed-last' over buffers too:
(package-vc-install "https://github.com/davidawad/reopen-closed-buffer.el")
(require 'reopen-closed-buffer)
(reopen-closed-buffer-mode 1)
(global-set-key (kbd "C-S-t") #'reopen-closed-last)          ; any key you like
```

Emacs 29.1, or by hand: clone the repositories and put them on
`load-path`.

```elisp
(add-to-list 'load-path "~/src/terra-emacs.el")
(add-to-list 'load-path "~/src/terra-emacs-capture.el")
(add-to-list 'load-path "~/src/reopen-closed-workspace.el")
(require 'reopen-closed-workspace)
(reopen-closed-workspace-mode 1)
```

## Commands

| Command | Does |
|---|---|
| `reopen-closed-workspace-mode` | global minor mode: capture each workspace as it closes |
| `reopen-closed-workspace` | reopen the most recently closed workspace and show it |
| `reopen-closed-workspace-list` | pick one of the closed workspaces (`completing-read`, newest first) and reopen it |
| `reopen-closed-last` | reopen whatever closed most recently, a buffer or a workspace |

## How it works

The mode hooks the closing of a workspace of the terra-emacs backend in
use:

| Backend | Hook | Notes |
|---|---|---|
| tab-bar | `tab-bar-tab-pre-close-functions` | `tab-bar-close-tab` and `tab-bar-close-other-tabs`. The frame's only tab is skipped when `tab-bar-close-last-tab-choice` is nil (it cannot close) |
| persp-mode | `persp-before-kill-functions` | `persp-kill`; the nil perspective is never recorded |

The capture is `terra-emacs-capture` of that workspace: name, id,
level, saved parameters and layout, each window a leaf record. A hidden
workspace is read off the window state its backend keeps, so capturing
shows nothing. The entry adds the time, the workspace's 0-based
position, its level's declaration and the names of the buffers it
showed.

Reopening builds the partial state
`(:terra-emacs 1 :partial t :current NAME :workspaces (WS))` and
`terra-emacs-apply`s it. The engine creates the workspace with its old
id, puts it in its level (declaring the level again when it is no
longer declared), lays it out and shows it; then the workspace moves
back to its old position. Each leaf reuses a live buffer when there is
one: a tab-bar tab's terminals and Claude sessions outlive the tab, so
the same processes come back. Buffers that died, as a killed
perspective's do (with `persp-autokill-buffer-on-remove`), are
restored: a terminal re-runs its command in its directory, and a Claude
session is resumed by id. A session live elsewhere gets a read-only
view instead of a second writer; that rule is the engine's.

A workspace whose id is open again is only shown. One whose name was
taken since comes back as `NAME<2>`.

`reopen-closed-last` compares the newest entries of the two rings by
time. Buffers that died because their perspective was killed (recorded
just after it, named in its entry) count as part of that close: the
workspace reopens and brings them back, and they leave the buffer ring.
Without reopen-closed-buffer loaded, it reopens workspaces only.

## Options

| Option | Default |
|---|---|
| `reopen-closed-workspace-size` | 20 entries, one per workspace id |
| `reopen-closed-workspace-file` | `reopen-closed-workspace.eld` in `user-emacs-directory`, rewritten on every change so the ring survives a restart; nil keeps it in memory |
| `reopen-closed-workspace-ignore-predicate` | `ignore`; a function of the backend and the workspace name, non-nil skips it |

## Tests

`make test` byte-compiles the package with warnings as errors, then
runs each `test/test-*.el` ERT suite in its own batch Emacs: capture on
close (tab-bar, hidden and shown, and persp-mode), the ring and its
file (including a real restart: one child Emacs closes a tab, the next
reopens it with its windows), reopening in tab-bar and persp-mode
(level, order, layout, an eat terminal reused or re-run, a fake Claude
session reused, never started twice), and the ordering of
`reopen-closed-last`, with and without reopen-closed-buffer loaded.
The engine, the exporter and reopen-closed-buffer come from
`TERRA_EMACS_DIR`, `TERRA_EMACS_CAPTURE_DIR` and
`REOPEN_CLOSED_BUFFER_DIR` (defaults: sibling checkouts). eat, compat
and persp-mode come from `TERRA_EMACS_TEST_PACKAGES`, the
colon-separated directories in `TERRA_EMACS_TEST_LOAD_PATH`, or else
your own Emacs's installed copies; tests needing one skip without it.

```sh
for r in terra-emacs terra-emacs-capture reopen-closed-buffer; do
  git clone "https://github.com/davidawad/$r.el" "../$r.el"
done
make test
```

## License

MIT. See [LICENSE](LICENSE).
