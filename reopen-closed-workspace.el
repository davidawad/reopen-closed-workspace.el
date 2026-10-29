;;; reopen-closed-workspace.el --- Reopen closed tabs and perspectives, processes and all -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (terra-emacs "0.2.0") (terra-emacs-capture "0.2.0"))
;; Keywords: convenience, frames
;; URL: https://github.com/davidawad/reopen-closed-workspace.el
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A browser's "reopen closed tab" for Emacs workspaces.  With
;; `reopen-closed-workspace-mode' on, closing a workspace of the
;; terra-emacs backend in use (a tab-bar tab, a persp-mode perspective)
;; captures its full state first, through terra-emacs-capture: name,
;; id, level (tab group), saved parameters, position, and the layout
;; with every leaf (files, terminals with their commands, Claude Code
;; sessions by id).  The captures go on a bounded ring saved to
;; `reopen-closed-workspace-file', so they survive a restart.
;;
;;   `reopen-closed-workspace'        reopen the most recently closed one
;;   `reopen-closed-workspace-list'   pick one from the ring
;;   `reopen-closed-last'             reopen whatever closed last, buffer
;;                                    or workspace (buffers come from
;;                                    reopen-closed-buffer, when loaded)
;;
;; Reopening is a partial state applied by the engine
;; (`terra-emacs-apply'): it creates the workspace, levels it, lays it
;; out (reusing a live buffer for each leaf, so a process starts only
;; where one is missing, and resuming a Claude session only where none
;; writes to it already) and shows it; the workspace then moves back to
;; its old position.  Nothing else changes.
;;
;; The hooks are `tab-bar-tab-pre-close-functions' and
;; `persp-before-kill-functions'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'terra-emacs)
(require 'terra-emacs-capture)

(defvar persp-before-kill-functions)
(declare-function persp-name "persp-mode" (persp))

(defgroup reopen-closed-workspace nil
  "Reopen closed workspaces through terra-emacs."
  :group 'convenience
  :prefix "reopen-closed-workspace-")

(defcustom reopen-closed-workspace-size 20
  "How many closed workspaces the ring keeps."
  :type 'natnum)

(defcustom reopen-closed-workspace-file (locate-user-emacs-file "reopen-closed-workspace.eld")
  "Where the ring is saved, so it survives a restart; nil keeps it in memory."
  :type '(choice (const :tag "Do not save" nil) file))

(defcustom reopen-closed-workspace-ignore-predicate #'ignore
  "A function of a backend and a workspace name: non-nil skips recording it."
  :type 'function)

(defvar reopen-closed-workspace-ring nil
  "The closed workspaces, newest first.
Each entry is a plist: :time (a float), :backend, :workspace (its
captured state: :name :id :level :parameters :layout), :index (its
0-based position), :level-declaration (the (:id :name) plist of its
level, when declared) and :buffers (the buffer names its leaves show).")

(defvar reopen-closed-workspace--loaded nil
  "Non-nil once `reopen-closed-workspace-file' has been read.")

(defvar reopen-closed-workspace--inhibit nil
  "Non-nil while closes are not recorded (while this package applies).")

;;;; The ring and its file

(defun reopen-closed-workspace--readable-p (object)
  "Non-nil when OBJECT prints as something `read' gives back."
  (condition-case nil
      (equal (car (read-from-string (prin1-to-string object))) object)
    (error nil)))

(defun reopen-closed-workspace--trim (entries)
  "ENTRIES without later ones of the same id, at most the ring's size."
  (let ((seen nil) (kept nil))
    (dolist (e entries)
      (let ((id (plist-get (plist-get e :workspace) :id)))
        (unless (and id (member id seen))
          (push id seen)
          (push e kept))))
    (seq-take (nreverse kept) reopen-closed-workspace-size)))

(defun reopen-closed-workspace-load ()
  "Read the ring saved in `reopen-closed-workspace-file', once.
Entries already on the ring stay ahead of the saved ones."
  (unless reopen-closed-workspace--loaded
    (setq reopen-closed-workspace--loaded t)
    (let ((file reopen-closed-workspace-file))
      (when (and file (file-readable-p file))
        (let ((saved (condition-case err
                         (with-temp-buffer
                           (insert-file-contents file)
                           (read (current-buffer)))
                       (error (message "reopen-closed-workspace: cannot read %s: %s"
                                       file (error-message-string err))
                              nil))))
          (when (listp saved)
            (setq reopen-closed-workspace-ring
                  (reopen-closed-workspace--trim
                   (append reopen-closed-workspace-ring
                           (cl-remove-if-not (lambda (e) (and (consp e) (plist-get e :workspace)))
                                             saved))))))))))

(defun reopen-closed-workspace-save ()
  "Write the ring to `reopen-closed-workspace-file'."
  (let ((file reopen-closed-workspace-file))
    (when file
      (let ((print-length nil) (print-level nil) (print-circle nil))
        (make-directory (file-name-directory (expand-file-name file)) t)
        (with-temp-file file
          (insert ";; reopen-closed-workspace ring -*- mode: lisp-data -*-\n")
          (prin1 reopen-closed-workspace-ring (current-buffer))
          (insert "\n"))))))

(defun reopen-closed-workspace-entries ()
  "The ring, newest first (read from its file the first time)."
  (reopen-closed-workspace-load)
  reopen-closed-workspace-ring)

;;;; Recording a close

(defun reopen-closed-workspace-describe (backend name)
  "The ring entry for BACKEND's workspace NAME, captured now."
  (let* ((ws (terra-emacs-state-clean (terra-emacs-capture name backend)))
         (level (plist-get ws :level))
         (entry (list :time (float-time) :backend backend :workspace ws
                      :index (cl-position name (terra-emacs-backend-workspaces backend) :test #'equal)
                      :level-declaration
                      (and level (cl-find level (terra-emacs-backend-levels backend)
                                          :key (lambda (l) (plist-get l :id)) :test #'equal))
                      :buffers (delete-dups
                                (delq nil (mapcar (lambda (r) (terra-emacs-leaf-prop r 'buffer-name))
                                                  (terra-emacs-layout-leaves
                                                   (plist-get ws :layout))))))))
    (and (reopen-closed-workspace--readable-p entry) entry)))

(defun reopen-closed-workspace--record (backend name)
  "Capture BACKEND's workspace NAME onto the ring, when BACKEND is in use."
  (unless (or reopen-closed-workspace--inhibit
              (not (stringp name))
              (not (eq backend (ignore-errors (terra-emacs-current-backend))))
              (funcall reopen-closed-workspace-ignore-predicate backend name))
    (condition-case err
        (let ((entry (reopen-closed-workspace-describe backend name)))
          (when entry
            (reopen-closed-workspace-load)
            (setq reopen-closed-workspace-ring
                  (reopen-closed-workspace--trim (cons entry reopen-closed-workspace-ring)))
            (reopen-closed-workspace-save)))
      (error (message "reopen-closed-workspace: %s not recorded: %s"
                      name (error-message-string err))))))

(defun reopen-closed-workspace--tab-closing (tab last-tab-p)
  "Record TAB before it closes (`tab-bar-tab-pre-close-functions').
LAST-TAB-P: it is the frame's only tab, which closes only when
`tab-bar-close-last-tab-choice' says what to do instead."
  (unless (and last-tab-p (null tab-bar-close-last-tab-choice))
    (reopen-closed-workspace--record 'tab-bar (alist-get 'name tab))))

(defun reopen-closed-workspace--persp-killing (persp)
  "Record PERSP before it is killed (`persp-before-kill-functions')."
  (when persp                           ; never the nil perspective
    (reopen-closed-workspace--record 'persp-mode (persp-name persp))))

;;;###autoload
(define-minor-mode reopen-closed-workspace-mode
  "Record closed workspaces so `reopen-closed-workspace' can bring them back."
  :global t
  :group 'reopen-closed-workspace
  (if reopen-closed-workspace-mode
      (progn (reopen-closed-workspace-load)
             (add-hook 'tab-bar-tab-pre-close-functions #'reopen-closed-workspace--tab-closing)
             (add-hook 'persp-before-kill-functions #'reopen-closed-workspace--persp-killing))
    (remove-hook 'tab-bar-tab-pre-close-functions #'reopen-closed-workspace--tab-closing)
    (remove-hook 'persp-before-kill-functions #'reopen-closed-workspace--persp-killing)))

;;;; Reopening

(defun reopen-closed-workspace--free-name (backend name)
  "NAME, or NAME<N> when BACKEND already has a workspace NAME."
  (let ((names (terra-emacs-backend-workspaces backend)))
    (if (not (member name names))
        name
      (cl-loop for n from 2 for try = (format "%s<%d>" name n)
               unless (member try names) return try))))

(defun reopen-closed-workspace--state (backend entry)
  "The partial state that brings ENTRY's workspace back in BACKEND."
  (let* ((ws (copy-sequence (plist-get entry :workspace)))
         (name (reopen-closed-workspace--free-name backend (plist-get ws :name)))
         (decl (plist-get entry :level-declaration))
         (levels (terra-emacs-backend-levels backend)))
    (setq ws (plist-put ws :name name))
    (append (list :terra-emacs terra-emacs-format-version :backend backend :partial t)
            (when (and decl (not (cl-find (plist-get decl :id) levels
                                          :key (lambda (l) (plist-get l :id)) :test #'equal)))
              (list :levels (append levels (list decl))))
            (list :current name :workspaces (list ws)))))

(defun reopen-closed-workspace--forget-buffers (entry)
  "Drop from reopen-closed-buffer's ring what closed with ENTRY's workspace."
  (when (fboundp 'reopen-closed-buffer-forget)
    (let ((keys (mapcar #'terra-emacs-leaf-key
                        (terra-emacs-layout-leaves (plist-get (plist-get entry :workspace) :layout))))
          (since (plist-get entry :time)))
      (reopen-closed-buffer-forget
       (lambda (e) (and (>= (plist-get e :time) since)
                        (member (terra-emacs-leaf-key (plist-get e :record)) keys)))))))

(defun reopen-closed-workspace-reopen (entry)
  "Bring ENTRY's workspace back, show it and drop ENTRY from the ring.
Return the workspace's name."
  (let* ((backend (terra-emacs-current-backend))
         (ws (plist-get entry :workspace))
         (id (plist-get ws :id))
         (open (and id (cl-find id (terra-emacs-backend-workspaces backend)
                                :key (lambda (n) (terra-emacs-backend-id backend n))
                                :test #'equal))))
    (setq reopen-closed-workspace-ring (delq entry (reopen-closed-workspace-entries)))
    (reopen-closed-workspace-save)
    (if open
        (progn (terra-emacs-backend-select backend open)
               (message "reopen-closed-workspace: %s is open already" open)
               open)
      (let* ((state (reopen-closed-workspace--state backend entry))
             (name (plist-get state :current))
             (index (plist-get entry :index)))
        (let ((reopen-closed-workspace--inhibit t))
          (terra-emacs-apply state nil backend)
          (when index
            (terra-emacs-backend-move backend name
                                      (min index (1- (length (terra-emacs-backend-workspaces backend)))))))
        (reopen-closed-workspace--forget-buffers entry)
        name))))

;;;###autoload
(defun reopen-closed-workspace (&optional entry)
  "Reopen the most recently closed workspace (or ENTRY of the ring).
Return its name."
  (interactive)
  (reopen-closed-workspace-reopen
   (or entry (car (reopen-closed-workspace-entries))
       (user-error "No closed workspace to reopen"))))

(defun reopen-closed-workspace--label (entry)
  "ENTRY as a line for completion."
  (let ((ws (plist-get entry :workspace)))
    (format "%s  [%s%d window%s]  %s" (plist-get ws :name)
            (if (plist-get ws :level) (format "%s, " (plist-get ws :level)) "")
            (length (terra-emacs-layout-leaves (plist-get ws :layout)))
            (if (= 1 (length (terra-emacs-layout-leaves (plist-get ws :layout)))) "" "s")
            (format-time-string "%F %R" (plist-get entry :time)))))

;;;###autoload
(defun reopen-closed-workspace-list ()
  "Pick a closed workspace from the ring and reopen it."
  (interactive)
  (let* ((entries (or (reopen-closed-workspace-entries)
                      (user-error "No closed workspace to reopen")))
         (labels (mapcar (lambda (e) (cons (reopen-closed-workspace--label e) e)) entries))
         (table (lambda (string pred action)
                  (if (eq action 'metadata)
                      '(metadata (display-sort-function . identity))
                    (complete-with-action action labels string pred))))
         (choice (completing-read "Reopen workspace: " table nil t)))
    (reopen-closed-workspace-reopen (cdr (assoc choice labels)))))

;;;; Whatever closed last

(declare-function reopen-closed-buffer-entries "reopen-closed-buffer" ())
(declare-function reopen-closed-buffer "reopen-closed-buffer" (&optional entry))
(declare-function reopen-closed-buffer-forget "reopen-closed-buffer" (predicate))

(defun reopen-closed-workspace--last-buffer (ws)
  "reopen-closed-buffer's newest entry that did not close with WS's workspace.
A buffer killed as its perspective was killed comes back with it."
  (when (fboundp 'reopen-closed-buffer-entries)
    (cl-find-if-not (lambda (e)
                      (and ws (>= (plist-get e :time) (plist-get ws :time))
                           (member (plist-get e :name) (plist-get ws :buffers))))
                    (reopen-closed-buffer-entries))))

;;;###autoload
(defun reopen-closed-last ()
  "Reopen whatever was closed most recently: a buffer or a workspace.
Buffers come from reopen-closed-buffer when it is loaded; without it
this reopens the last workspace.  Return the buffer or workspace name."
  (interactive)
  (let* ((ws (car (reopen-closed-workspace-entries)))
         (buf (reopen-closed-workspace--last-buffer ws)))
    (cond ((and buf (or (null ws) (> (plist-get buf :time) (plist-get ws :time))))
           (reopen-closed-buffer buf))
          (ws (reopen-closed-workspace-reopen ws))
          (t (user-error "Nothing closed to reopen")))))

(provide 'reopen-closed-workspace)
;;; reopen-closed-workspace.el ends here
