;;; test-reopen-closed-last.el --- `reopen-closed-last' with reopen-closed-buffer -*- lexical-binding: t; -*-

;;; Commentary:
;; Buffers and workspaces interleaved: `reopen-closed-last' reopens them
;; newest first, whichever kind each is.  Buffers killed because their
;; perspective was killed close with it: the workspace reopens first and
;; brings them back, and they leave the buffer ring.

;;; Code:

(require 'reopen-closed-workspace-test-helper
         (expand-file-name "reopen-closed-workspace-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'reopen-closed-buffer)

(defmacro rcw-test-with-both-rings (&rest body)
  "Run BODY with both modes on and both rings empty."
  (declare (indent 0))
  `(let ((reopen-closed-buffer-file (expand-file-name "buffers.eld" (rcw-test-tmpdir)))
         (reopen-closed-buffer-ring nil)
         (reopen-closed-buffer--loaded nil))
     (reopen-closed-buffer-mode 1)
     (unwind-protect (rcw-test-with-ring ,@body)
       (reopen-closed-buffer-mode -1))))

(ert-deftest reopen-closed-last-follows-the-order-of-closing ()
  (rcw-test-reset-tabs)
  (rcw-test-with-both-rings
    (let* ((dir (rcw-test-tmpdir))
           (a (rcw-test-file "a.txt" dir))
           (b (rcw-test-file "b.txt" dir)))
      (kill-buffer (find-file-noselect a))                     ; 1. buffer a
      (terra-emacs-backend-create 'tab-bar "ws")
      (terra-emacs-backend-kill 'tab-bar "ws")                 ; 2. workspace ws
      (kill-buffer (find-file-noselect b))                     ; 3. buffer b
      (let ((got (list (reopen-closed-last) (reopen-closed-last) (reopen-closed-last))))
        (should (equal (buffer-file-name (nth 0 got)) b))
        (should (equal (nth 1 got) "ws"))
        (should (equal (buffer-file-name (nth 2 got)) a)))
      (should-error (reopen-closed-last) :type 'user-error))))

(ert-deftest reopen-closed-last-uses-the-times-on-the-rings ()
  ;; Same order whatever order the rings were filled in.
  (rcw-test-reset-tabs)
  (rcw-test-with-both-rings
    (let ((f (rcw-test-file "late.txt")))
      (terra-emacs-backend-create 'tab-bar "early")
      (terra-emacs-backend-kill 'tab-bar "early")
      (kill-buffer (find-file-noselect f))
      (setf (plist-get (car reopen-closed-buffer-ring) :time) 100.0)
      (setf (plist-get (car reopen-closed-workspace-ring) :time) 200.0)
      (should (equal (reopen-closed-last) "early"))
      (should (equal (buffer-file-name (reopen-closed-last)) f)))))

(ert-deftest reopen-closed-last-a-perspective-comes-back-with-its-buffers ()
  (skip-unless (rcw-test-have 'persp-mode))
  (rcw-test-persp-on)
  (unwind-protect
      (rcw-test-with-both-rings
        (let ((terra-emacs-backend 'persp-mode)
              (persp-autokill-buffer-on-remove 'kill-weak)
              (a (rcw-test-file "a.txt"))
              (other (rcw-test-file "other.txt")))
          (kill-buffer (find-file-noselect other))
          (terra-emacs-backend-create 'persp-mode "one")
          (terra-emacs-backend-create 'persp-mode "two")
          (persp-switch "two")
          (find-file a)
          (persp-switch "one")
          (persp-kill "two")
          ;; a.txt died after the perspective was captured, with it.
          (should (equal (plist-get (car reopen-closed-buffer-ring) :name) "a.txt"))
          (should (equal (reopen-closed-last) "two"))
          (should (equal (buffer-file-name (window-buffer (selected-window))) a))
          (should (equal (mapcar (lambda (e) (plist-get e :name)) reopen-closed-buffer-ring)
                         '("other.txt")))
          (should (equal (buffer-file-name (reopen-closed-last)) other))))
    (rcw-test-persp-off)))

(provide 'test-reopen-closed-last)
;;; test-reopen-closed-last.el ends here
