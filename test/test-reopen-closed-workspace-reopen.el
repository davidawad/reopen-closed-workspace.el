;;; test-reopen-closed-workspace-reopen.el --- reopening through terra-emacs -*- lexical-binding: t; -*-

;;; Commentary:
;; Reopening applies the captured workspace through the engine: name,
;; id, level, position, layout, and the processes its leaves run.  With
;; tab-bar a closed tab's terminal and Claude session are still live, so
;; they are reused (one writer); with persp-mode the killed buffers come
;; back, a terminal re-running its command.  A name taken since gets a
;; suffix; a workspace open already is only shown.

;;; Code:

(require 'reopen-closed-workspace-test-helper
         (expand-file-name "reopen-closed-workspace-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))

(defun rcw-test--layout-keys (backend name)
  "The leaf keys of BACKEND's workspace NAME, as the engine observes them."
  (mapcar #'terra-emacs-leaf-key (terra-emacs-layout-leaves (terra-emacs-layout-of backend name))))

(ert-deftest reopen-closed-workspace-reopens-a-tab ()
  (rcw-test-reset-tabs)
  (rcw-test-with-ring
    (let* ((dir (rcw-test-tmpdir))
           (a (rcw-test-file "a.txt" dir))
           (b (rcw-test-file "b.txt" dir))
           (terra-emacs-levels '((:id "ops" :name "Operations"))))
      (dolist (n '("code" "mail" "notes")) (terra-emacs-backend-create 'tab-bar n))
      (terra-emacs-backend-set-level 'tab-bar "code" "ops")  ; tab-bar moves it last
      (terra-emacs-backend-move 'tab-bar "code" 1)
      (terra-emacs-backend-with-workspace 'tab-bar "code" (lambda () (rcw-test-split a b)))
      (let ((id (plist-get (terra-emacs-capture "code" 'tab-bar) :id)))
        (terra-emacs-backend-kill 'tab-bar "code")
        ;; The levels are forgotten meanwhile: the reopen declares its own again.
        (setq terra-emacs-levels nil)
        (kill-buffer (get-file-buffer b))
        (should (equal (rcw-test-names 'tab-bar) '("main" "mail" "notes")))
        (should (equal (reopen-closed-workspace) "code"))
        (should (equal (rcw-test-names 'tab-bar) '("main" "code" "mail" "notes")))
        (should (equal (terra-emacs-backend-current 'tab-bar) "code"))
        (should (equal (terra-emacs-backend-id 'tab-bar "code") id))
        (should (equal (terra-emacs-backend-level 'tab-bar "code") "ops"))
        (should (equal terra-emacs-levels '((:id "ops" :name "Operations"))))
        (should (equal (mapcar (lambda (w) (buffer-file-name (window-buffer w)))
                               (window-list nil 'nomini (frame-first-window)))
                       (list a b)))
        (should (equal (buffer-file-name (window-buffer (selected-window))) a))
        (should-not reopen-closed-workspace-ring)
        ;; Converged: the engine plans nothing more for it.
        (should-not (terra-emacs-plan (list :partial t :workspaces
                                            (list (terra-emacs-capture "code" 'tab-bar)))
                                      'tab-bar))
        (should-error (reopen-closed-workspace) :type 'user-error)))))

(ert-deftest reopen-closed-workspace-name-taken-or-open-already ()
  (rcw-test-reset-tabs)
  (rcw-test-with-ring
    (terra-emacs-backend-create 'tab-bar "code")
    (terra-emacs-backend-kill 'tab-bar "code")
    (terra-emacs-backend-create 'tab-bar "code")      ; a new one, another id
    (should (equal (reopen-closed-workspace) "code<2>"))
    (should (equal (rcw-test-names 'tab-bar) '("main" "code<2>" "code")))
    ;; Its id open already (closed and reopened by hand): only shown.
    (let ((entry (reopen-closed-workspace-describe 'tab-bar "code")))
      (terra-emacs-backend-select 'tab-bar "main")
      (should (equal (reopen-closed-workspace entry) "code"))
      (should (equal (terra-emacs-backend-current 'tab-bar) "code"))
      (should (equal (rcw-test-names 'tab-bar) '("main" "code<2>" "code"))))))

(ert-deftest reopen-closed-workspace-reopens-a-tab-reusing-its-terminal ()
  (skip-unless (rcw-test-have 'eat))
  (rcw-test-reset-tabs)
  (rcw-test-with-ring
    (let ((buf (get-buffer-create "*rcw-eat*")))
      (unwind-protect
          (progn
            (terra-emacs-backend-create 'tab-bar "term")
            (terra-emacs-backend-with-workspace
             'tab-bar "term"
             (lambda ()
               (with-current-buffer buf
                 (eat-mode)
                 (eat-exec buf "rcw-eat" "/bin/sh" nil '("-c" "sleep 30")))
               (switch-to-buffer buf)))
            (let ((pid (process-id (get-buffer-process buf))))
              (terra-emacs-backend-kill 'tab-bar "term")
              (reopen-closed-workspace)
              (should (equal (rcw-test-shown) '("*rcw-eat*")))
              ;; tab-bar closes keep buffers: the same process, not a second one.
              (should (= pid (process-id (get-buffer-process buf))))))
        (rcw-test-kill buf)))))

(defun rcw-test--fake-claude (out sessions)
  "A fake claude writing its argv to OUT and its session file to SESSIONS."
  (let ((bin (expand-file-name "claude" (rcw-test-tmpdir))))
    (with-temp-file bin
      (insert "#!/bin/sh\n"
              "sid=none; prev=\n"
              "for a in \"$@\"; do echo \"$a\" >> " (shell-quote-argument out) "/argv.tmp;"
              " [ \"$prev\" = --resume ] && sid=\"$a\"; prev=\"$a\"; done\n"
              "printf '{\"pid\":%d,\"sessionId\":\"%s\",\"cwd\":\"%s\",\"status\":\"idle\"}'"
              " $$ \"$sid\" \"$PWD\" > " (shell-quote-argument sessions) "/$$.json\n"
              "mv " (shell-quote-argument out) "/argv.tmp " (shell-quote-argument out) "/argv\n"
              "sleep 30\n"))
    (set-file-modes bin #o755)
    bin))

(defun rcw-test--wait-for (file)
  "Wait up to 5s for FILE to exist; non-nil when it does."
  (cl-loop repeat 100 until (file-exists-p file) do (accept-process-output nil 0.05))
  (file-exists-p file))

(ert-deftest reopen-closed-workspace-claude-session-never-gets-two-writers ()
  (skip-unless (rcw-test-have 'eat))
  (rcw-test-reset-tabs)
  (rcw-test-with-ring
    (let* ((out (rcw-test-tmpdir))
           (terra-emacs-claude-sessions-directory (rcw-test-tmpdir))
           (fake (rcw-test--fake-claude out terra-emacs-claude-sessions-directory))
           (rec (terra-emacs-leaf-make "*claude rcw*" 'handler 'terra-emacs-claude-bookmark-handler
                                       'buffer-name "*claude rcw*" 'session-id "sess-rcw"
                                       'cwd temporary-file-directory 'argv (list fake)))
           (buf nil))
      (unwind-protect
          (progn
            (terra-emacs-apply (list :partial t :workspaces
                                     (list (list :name "agent" :layout (list :leaf rec))))
                               nil 'tab-bar)
            (setq buf (get-buffer "*claude rcw*"))
            (should (rcw-test--wait-for (expand-file-name "argv" out)))
            (delete-file (expand-file-name "argv" out))
            (let ((pid (process-id (get-buffer-process buf))))
              (terra-emacs-backend-kill 'tab-bar "agent")
              (should (equal (plist-get (car reopen-closed-workspace-ring) :buffers) '("*claude rcw*")))
              (reopen-closed-workspace)
              (should (equal (terra-emacs-backend-current 'tab-bar) "agent"))
              (should (equal (rcw-test-shown) '("*claude rcw*")))
              ;; The live session is reused: same process, claude not started again.
              (should (= pid (process-id (get-buffer-process buf))))
              (accept-process-output nil 0.3)
              (should-not (file-exists-p (expand-file-name "argv" out)))))
        (when buf (rcw-test-kill buf))))))

(ert-deftest reopen-closed-workspace-reopens-a-killed-perspective ()
  (skip-unless (rcw-test-have 'persp-mode))
  (skip-unless (rcw-test-have 'eat))
  (rcw-test-persp-on)
  (unwind-protect
      (rcw-test-with-ring
        (let* ((terra-emacs-backend 'persp-mode)
               (persp-autokill-buffer-on-remove 'kill-weak)
               (a (rcw-test-file "a.txt"))
               (term (get-buffer-create "*rcw-persp-eat*")))
          (unwind-protect
              (progn
                (dolist (n '("one" "two" "three")) (terra-emacs-backend-create 'persp-mode n))
                (terra-emacs-backend-set-level 'persp-mode "two" "home")
                (persp-switch "two")
                (delete-other-windows)
                (find-file a)
                (with-current-buffer term
                  (eat-mode)
                  (eat-exec term "rcw-persp-eat" "/bin/sh" nil '("-c" "sleep 30"))
                  ;; Killed with its perspective, without asking about its process.
                  (set-process-query-on-exit-flag (get-buffer-process term) nil))
                (select-window (split-window-right))
                (switch-to-buffer term)
                (persp-add-buffer term)
                (persp-switch "one")
                (persp-kill "two")              ; and its buffers
                (should-not (get-file-buffer a))
                (should-not (buffer-live-p term))
                (should (equal (rcw-test-names 'persp-mode) '("one" "three")))
                (should (equal (reopen-closed-workspace) "two"))
                (should (equal (rcw-test-names 'persp-mode) '("one" "two" "three")))
                (should (equal (terra-emacs-backend-current 'persp-mode) "two"))
                (should (equal (terra-emacs-backend-level 'persp-mode "two") "home"))
                (should (equal (buffer-file-name (window-buffer (frame-first-window))) a))
                (should (equal (cdr (rcw-test-shown)) '("*rcw-persp-eat*")))
                (setq term (get-buffer "*rcw-persp-eat*"))
                (should (process-live-p (get-buffer-process term)))
                (should (equal (rcw-test--layout-keys 'persp-mode "two")
                               (list (list 'file a)
                                     (list 'eat "*rcw-persp-eat*" '("/bin/sh" "-c" "sleep 30"))))))
            (rcw-test-kill term))))
    (rcw-test-persp-off)))

(provide 'test-reopen-closed-workspace-reopen)
;;; test-reopen-closed-workspace-reopen.el ends here
