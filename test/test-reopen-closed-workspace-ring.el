;;; test-reopen-closed-workspace-ring.el --- the bounded, persisted ring -*- lexical-binding: t; -*-

;;; Commentary:
;; The ring keeps the newest `reopen-closed-workspace-size' closes, one
;; per workspace id; its file round trip is equal; a tab closed in one
;; Emacs reopens, layout and all, in the next.

;;; Code:

(require 'reopen-closed-workspace-test-helper
         (expand-file-name "reopen-closed-workspace-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest reopen-closed-workspace-ring-is-bounded-and-one-per-id ()
  (rcw-test-reset-tabs)
  (rcw-test-with-ring
    (let ((reopen-closed-workspace-size 2))
      (dolist (n '("w1" "w2" "w3"))
        (terra-emacs-backend-create 'tab-bar n)
        (terra-emacs-backend-kill 'tab-bar n))
      (should (equal (mapcar (lambda (e) (plist-get (plist-get e :workspace) :name))
                             reopen-closed-workspace-ring)
                     '("w3" "w2")))
      ;; Reopened and closed again: one entry, at the head.
      (reopen-closed-workspace-list--pick "w2")
      (terra-emacs-backend-kill 'tab-bar "w2")
      (should (equal (mapcar (lambda (e) (plist-get (plist-get e :workspace) :name))
                             reopen-closed-workspace-ring)
                     '("w2" "w3"))))))

(defun reopen-closed-workspace-list--pick (name)
  "Reopen the ring's entry for workspace NAME through `reopen-closed-workspace-list'."
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt table &rest _)
               (cl-find-if (lambda (c) (string-prefix-p (concat name " ") c))
                           (all-completions "" table)))))
    (call-interactively #'reopen-closed-workspace-list)))

(ert-deftest reopen-closed-workspace-ring-file-round-trip ()
  (rcw-test-reset-tabs)
  (rcw-test-with-ring
    (let ((a (rcw-test-file "a.txt")))
      (terra-emacs-backend-create 'tab-bar "code")
      (terra-emacs-backend-with-workspace 'tab-bar "code" (lambda () (find-file a)))
      (terra-emacs-backend-kill 'tab-bar "code")
      (terra-emacs-backend-create 'tab-bar "mail")
      (terra-emacs-backend-kill 'tab-bar "mail")
      (let ((before reopen-closed-workspace-ring))
        (should (file-exists-p reopen-closed-workspace-file))
        (setq reopen-closed-workspace-ring nil reopen-closed-workspace--loaded nil)
        (should (equal (reopen-closed-workspace-entries) before)))
      ;; An unreadable file gives an empty ring, not an error.
      (with-temp-file reopen-closed-workspace-file (insert "(:unbalanced"))
      (setq reopen-closed-workspace-ring nil reopen-closed-workspace--loaded nil)
      (should-not (reopen-closed-workspace-entries)))))

(ert-deftest reopen-closed-workspace-survives-a-restart ()
  ;; One batch Emacs closes a tab showing two files and exits; the next
  ;; reopens it with both.
  (let* ((dir (rcw-test-tmpdir))
         (a (rcw-test-file "a.txt" dir))
         (b (rcw-test-file "b.txt" dir))
         (ring (expand-file-name "ring.eld" (rcw-test-tmpdir)))
         (emacs (expand-file-name invocation-name invocation-directory))
         (args (append (list "-Q" "--batch")
                       (cl-mapcan (lambda (d) (list "-L" d)) load-path)
                       (list "--eval" (format "(setq reopen-closed-workspace-file %S terra-emacs-backend 'tab-bar)" ring)
                             "-l" "reopen-closed-workspace" "-f" "reopen-closed-workspace-mode"))))
    (should (zerop (apply #'call-process emacs nil nil nil
                          (append args
                                  (list "--eval"
                                        (format "(progn (tab-bar-new-tab) (tab-bar-rename-tab \"code\")
                                                   (find-file %S) (split-window-right) (other-window 1)
                                                   (find-file %S) (tab-bar-close-tab))" a b))))))
    (should (file-exists-p ring))
    (with-temp-buffer
      (should (zerop (apply #'call-process emacs nil '(t nil) nil
                            (append args
                                    (list "--eval"
                                          "(progn (reopen-closed-workspace)
                                             (prin1 (list (terra-emacs-backend-current 'tab-bar)
                                                          (mapcar (lambda (w) (buffer-file-name (window-buffer w)))
                                                                  (window-list nil 'nomini (frame-first-window))))))")))))
      (should (equal (car (read-from-string (buffer-string))) (list "code" (list a b)))))))

(provide 'test-reopen-closed-workspace-ring)
;;; test-reopen-closed-workspace-ring.el ends here
