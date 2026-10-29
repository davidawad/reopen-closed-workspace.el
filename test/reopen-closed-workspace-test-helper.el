;;; reopen-closed-workspace-test-helper.el --- shared setup for reopen-closed-workspace ERT -*- lexical-binding: t; -*-

;;; Commentary:
;; Load paths (the package, the engine from TERRA_EMACS_DIR, the exporter
;; from TERRA_EMACS_CAPTURE_DIR, each defaulting to a sibling checkout,
;; and the pinned test packages for eat and persp-mode when present) and
;; the resets every suite uses.  reopen-closed-buffer, from
;; REOPEN_CLOSED_BUFFER_DIR or a sibling checkout, is on the load path
;; but not loaded: only the suites of `reopen-closed-last' with buffers
;; load it.  Batch Emacs has one 80x25 frame; tab-bar
;; works there, and so does persp-mode.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defconst rcw-test-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "This directory.")

(add-to-list 'load-path (expand-file-name ".." rcw-test-dir))

(dolist (spec '(("TERRA_EMACS_DIR" . "../../terra-emacs.el")
                ("TERRA_EMACS_CAPTURE_DIR" . "../../terra-emacs-capture.el")
                ("REOPEN_CLOSED_BUFFER_DIR" . "../../reopen-closed-buffer.el")))
  (add-to-list 'load-path (expand-file-name (or (getenv (car spec))
                                                (expand-file-name (cdr spec) rcw-test-dir)))))

(defconst rcw-test-packages
  (or (getenv "TERRA_EMACS_TEST_PACKAGES") "/opt/emacs-test-packages")
  "Where the pinned third-party test packages live.")

(dolist (dir (append (list (expand-file-name "eat-0.9.4" rcw-test-packages)
                           (expand-file-name "external/pkg-persp-mode" rcw-test-packages))
                     (split-string (or (getenv "TERRA_EMACS_TEST_LOAD_PATH") "") ":" t)))
  (when (file-directory-p dir) (add-to-list 'load-path (expand-file-name dir) t)))

(require 'reopen-closed-workspace)

(defun rcw-test-have (feature)
  "Non-nil when FEATURE loads."
  (ignore-errors (require feature) t))

(defun rcw-test-tmpdir ()
  "A fresh temporary directory (with a trailing slash)."
  (file-name-as-directory (make-temp-file "reopen-closed-workspace-test" t)))

(defun rcw-test-file (name &optional dir)
  "A fresh file NAME (in DIR, else a new temp dir) with three lines; its path."
  (let ((f (expand-file-name name (or dir (rcw-test-tmpdir)))))
    (with-temp-file f (insert "line one\nline two\nline three\n"))
    f))

(defun rcw-test-reset-tabs ()
  "Leave one tab, named \"main\", showing *scratch* in one window."
  (require 'tab-bar)
  (let ((reopen-closed-workspace--inhibit t))
    (while (> (length (funcall tab-bar-tabs-function)) 1)
      (tab-bar-close-tab 2)))
  (let ((tab (assq 'current-tab (funcall tab-bar-tabs-function))))
    (setcdr tab (cl-remove-if (lambda (c) (memq (car-safe c) '(terra-emacs-id group)))
                              (cdr tab))))
  (tab-bar-rename-tab "main")
  (delete-other-windows)
  (switch-to-buffer "*scratch*"))

(defun rcw-test-persp-on ()
  "Turn persp-mode on with no autosave/resume; kill every perspective."
  (require 'persp-mode)
  (setq persp-auto-resume-time -1 persp-auto-save-opt 0)
  (unless (bound-and-true-p persp-mode) (persp-mode 1))
  (let ((reopen-closed-workspace--inhibit t))
    (dolist (name (persp-names))
      (unless (equal name persp-nil-name) (persp-kill name t))))
  (delete-other-windows)
  (switch-to-buffer "*scratch*"))

(defun rcw-test-persp-off ()
  "Turn persp-mode off."
  (when (bound-and-true-p persp-mode) (persp-mode -1)))

(defun rcw-test-kill (buffer)
  "Kill BUFFER and its process quietly."
  (when (buffer-live-p buffer)
    (let ((p (get-buffer-process buffer)))
      (when p (set-process-query-on-exit-flag p nil)))
    (let ((kill-buffer-query-functions nil)) (kill-buffer buffer))))

(defmacro rcw-test-with-ring (&rest body)
  "Run BODY with the mode on, an empty ring and a fresh ring file."
  (declare (indent 0))
  `(let ((reopen-closed-workspace-file (expand-file-name "ring.eld" (rcw-test-tmpdir)))
         (reopen-closed-workspace-ring nil)
         (reopen-closed-workspace--loaded nil)
         (terra-emacs-backend 'tab-bar)
         (terra-emacs-levels nil))
     (reopen-closed-workspace-mode 1)
     (unwind-protect (progn ,@body)
       (reopen-closed-workspace-mode -1))))

(defun rcw-test-names (backend)
  "BACKEND's workspace names, in order."
  (terra-emacs-backend-workspaces backend))

(defun rcw-test-shown ()
  "The buffer names the selected frame shows, in window order."
  (mapcar (lambda (w) (buffer-name (window-buffer w)))
          (window-list nil 'nomini (frame-first-window))))

(defun rcw-test-split (a b)
  "Show files A | B in the selected frame, A's window selected."
  (delete-other-windows)
  (find-file a)
  (with-selected-window (split-window-right) (find-file b)))

(provide 'reopen-closed-workspace-test-helper)
;;; reopen-closed-workspace-test-helper.el ends here
