;;; test-reopen-closed-last-alone.el --- `reopen-closed-last' without reopen-closed-buffer -*- lexical-binding: t; -*-

;;; Commentary:
;; reopen-closed-buffer not loaded: `reopen-closed-last' reopens the
;; last workspace, and says so when there is none.

;;; Code:

(require 'reopen-closed-workspace-test-helper
         (expand-file-name "reopen-closed-workspace-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest reopen-closed-last-alone-reopens-workspaces ()
  (should-not (featurep 'reopen-closed-buffer))
  (rcw-test-reset-tabs)
  (rcw-test-with-ring
    (should-error (reopen-closed-last) :type 'user-error)
    (terra-emacs-backend-create 'tab-bar "one")
    (terra-emacs-backend-create 'tab-bar "two")
    (terra-emacs-backend-kill 'tab-bar "one")
    (kill-buffer (find-file-noselect (rcw-test-file "a.txt")))
    (terra-emacs-backend-kill 'tab-bar "two")
    (should (equal (reopen-closed-last) "two"))
    (should (equal (reopen-closed-last) "one"))
    (should (equal (rcw-test-names 'tab-bar) '("main" "one" "two")))
    (should-error (reopen-closed-last) :type 'user-error)
    (should-not (featurep 'reopen-closed-buffer))))

(provide 'test-reopen-closed-last-alone)
;;; test-reopen-closed-last-alone.el ends here
