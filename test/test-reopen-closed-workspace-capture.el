;;; test-reopen-closed-workspace-capture.el --- recording a close -*- lexical-binding: t; -*-

;;; Commentary:
;; Closing a tab (shown or hidden) or killing a perspective captures
;; its full state first: name, id, level, position, layout and leaves.
;; Closes of a backend not in use, the frame's last tab when it cannot
;; close, and what the predicate skips are not recorded.

;;; Code:

(require 'reopen-closed-workspace-test-helper
         (expand-file-name "reopen-closed-workspace-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest reopen-closed-workspace-records-a-closed-tab ()
  (rcw-test-reset-tabs)
  (rcw-test-with-ring
    (let* ((dir (rcw-test-tmpdir))
           (a (rcw-test-file "a.txt" dir))
           (b (rcw-test-file "b.txt" dir))
           (c (rcw-test-file "c.txt" dir)))
      (terra-emacs-backend-create 'tab-bar "code")
      (terra-emacs-backend-create 'tab-bar "notes")
      (terra-emacs-backend-set-level 'tab-bar "code" "ops")  ; tab-bar moves it last
      (terra-emacs-backend-move 'tab-bar "code" 1)
      (terra-emacs-backend-with-workspace 'tab-bar "code" (lambda () (rcw-test-split a b)))
      (terra-emacs-backend-with-workspace 'tab-bar "notes" (lambda () (find-file c)))
      ;; A hidden tab: read off its window state.
      (tab-bar-close-tab 2)
      (let* ((e (car reopen-closed-workspace-ring))
             (ws (plist-get e :workspace)))
        (should (equal (plist-get ws :name) "code"))
        (should (stringp (plist-get ws :id)))
        (should (equal (plist-get ws :level) "ops"))
        (should (eql (plist-get e :index) 1))
        (should (eq (plist-get e :backend) 'tab-bar))
        (should (eq (plist-get (plist-get ws :layout) :split) 'right))
        (should (equal (mapcar #'terra-emacs-leaf-key (terra-emacs-layout-leaves (plist-get ws :layout)))
                       (list (list 'file a) (list 'file b))))
        (should (equal (plist-get e :buffers) '("a.txt" "b.txt"))))
      ;; The shown tab.
      (terra-emacs-backend-select 'tab-bar "notes")
      (tab-bar-close-tab)
      (should (equal (mapcar (lambda (e) (plist-get (plist-get e :workspace) :name))
                             reopen-closed-workspace-ring)
                     '("notes" "code")))
      (should (equal (terra-emacs-layout-leaves
                      (plist-get (plist-get (car reopen-closed-workspace-ring) :workspace) :layout))
                     (list (terra-emacs-capture-leaf (get-file-buffer c))))))))

(ert-deftest reopen-closed-workspace-records-a-killed-perspective ()
  (skip-unless (rcw-test-have 'persp-mode))
  (rcw-test-persp-on)
  (unwind-protect
      (rcw-test-with-ring
        (let ((terra-emacs-backend 'persp-mode)
              (a (rcw-test-file "a.txt")))
          (terra-emacs-backend-create 'persp-mode "one")
          (terra-emacs-backend-create 'persp-mode "two")
          (terra-emacs-backend-set-level 'persp-mode "two" "home")
          (persp-switch "two")
          (find-file a)
          (persp-switch "one")
          (persp-kill "two")
          (let* ((e (car reopen-closed-workspace-ring))
                 (ws (plist-get e :workspace)))
            (should (eq (plist-get e :backend) 'persp-mode))
            (should (equal (plist-get ws :name) "two"))
            (should (equal (plist-get ws :level) "home"))
            (should (eql (plist-get e :index) 1))
            (should (equal (mapcar #'terra-emacs-leaf-key (terra-emacs-layout-leaves (plist-get ws :layout)))
                           (list (list 'file a)))))))
    (rcw-test-persp-off)))

(ert-deftest reopen-closed-workspace-skips-what-is-not-a-closing-workspace ()
  (rcw-test-reset-tabs)
  (rcw-test-with-ring
    ;; The frame's last tab does not close when nothing replaces it.
    (let ((tab-bar-close-last-tab-choice nil))
      (should-error (tab-bar-close-tab)))
    ;; Tabs are not the workspaces while another backend is in use.
    (let ((terra-emacs-backend 'persp-mode))
      (tab-bar-new-tab)
      (tab-bar-close-tab))
    ;; The predicate is the user's.
    (let ((reopen-closed-workspace-ignore-predicate (lambda (_backend name) (equal name "scratchpad"))))
      (terra-emacs-backend-create 'tab-bar "scratchpad")
      (terra-emacs-backend-kill 'tab-bar "scratchpad"))
    (should-not reopen-closed-workspace-ring)
    ;; The mode off, nothing is recorded.
    (reopen-closed-workspace-mode -1)
    (terra-emacs-backend-create 'tab-bar "gone")
    (terra-emacs-backend-kill 'tab-bar "gone")
    (should-not reopen-closed-workspace-ring)))

(provide 'test-reopen-closed-workspace-capture)
;;; test-reopen-closed-workspace-capture.el ends here
