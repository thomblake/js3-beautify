;;; js3-bfy-indent.el --- indentation for js3-bfy

;;; Code:

(defconst js3-bfy-possibly-braceless-keyword-re
  (regexp-opt
   '("catch" "do" "else" "finally" "for" "if" "try" "while" "with" "let" "each")
   'words)
  "Regular expression matching keywords that are optionally
followed by an opening brace.")

(defconst js3-bfy-indent-operator-re
  (concat "[-+*/%<>=&^|?:.]\\([^-+*/]\\|$\\)\\|"
          (regexp-opt '("in" "instanceof") 'words))
  "Regular expression matching operators that affect indentation
of continued expressions.")

(defconst js3-bfy-indent-operator-first-re
  (concat "[-+*/%<>!=&^|?:.]\\([^-+*/]\\|$\\)\\|"
          (regexp-opt '("in" "instanceof") 'words))
  "Regular expression matching operators that affect indentation
of continued expressions with operator-first style.")

(defconst js3-bfy-indent-brace-re
  "[[({]"
  "Regexp matching opening braces that affect indentation.")

(defconst js3-bfy-indent-operator-brace-re
  "[[(]"
  "Regexp matching opening braces that affect operator indentation.")

(defconst js3-bfy-skip-newlines-re
  "[ \t\n]*"
  "Regexp matching any amount of trailing whitespace and newlines.")

(defconst js3-bfy-opt-cpp-start "^\\s-*#\\s-*\\([[:alnum:]]+\\)"
  "Regexp matching the prefix of a cpp directive.
This includes the directive name, or nil in languages without
preprocessor support.  The first submatch surrounds the directive
name.")

(defun js3-bfy-backward-sws ()
  "Move backward through whitespace and comments."
  (interactive)
  (while (forward-comment -1)))

(defun js3-bfy-forward-sws ()
  "Move forward through whitespace and comments."
  (interactive)
  (while (forward-comment 1)))

(defun js3-bfy-beginning-of-macro (&optional lim)
  (let ((here (point)))
    (save-restriction
      (if lim (narrow-to-region lim (point-max)))
      (beginning-of-line)
      (while (eq (char-before (1- (point))) ?\\)
        (forward-line -1))
      (back-to-indentation)
      (if (and (<= (point) here)
               (looking-at js3-bfy-opt-cpp-start))
          t
        (goto-char here)
        nil))))

;; This function has horrible results if you're typing an array
;; such as [[1, 2], [3, 4], [5, 6]].  Bounce indenting -really- sucks
;; in conjunction with electric-indent, so just disabling it.
(defsubst js3-bfy-code-at-bol-p ()
  "Return t if the first character on line is non-whitespace."
  nil)

(defun js3-bfy-insert-and-indent (key)
  "Run command bound to key and indent current line. Runs the command
bound to KEY in the global keymap and indents the current line."
  (interactive (list (this-command-keys)))
  (let ((cmd (lookup-key (current-global-map) key)))
    (if (commandp cmd)
        (call-interactively cmd)))
  ;; don't do the electric keys inside comments or strings,
  ;; and don't do bounce-indent with them.
  (let ((parse-state (parse-partial-sexp (point-min) (point)))
        (js3-bfy-bounce-indent-p (js3-bfy-code-at-bol-p)))
    (unless (or (nth 3 parse-state)
                (nth 4 parse-state))
      (indent-according-to-mode))))


(defun js3-bfy-re-search-forward-inner (regexp &optional bound count)
  "Helper function for `js3-bfy-re-search-forward'."
  (let ((parse)
        str-terminator
        (orig-macro-end (save-excursion
                          (when (js3-bfy-beginning-of-macro)
                            (c-end-of-macro)
                            (point)))))
    (while (> count 0)
      (re-search-forward regexp bound)
      (setq parse (syntax-ppss))
      (cond ((setq str-terminator (nth 3 parse))
             (when (eq str-terminator t)
               (setq str-terminator ?/))
             (re-search-forward
              (concat "\\([^\\]\\|^\\)" (string str-terminator))
              (point-at-eol) t))
            ((nth 7 parse)
             (forward-line))
            ((or (nth 4 parse)
                 (and (eq (char-before) ?\/) (eq (char-after) ?\*)))
             (re-search-forward "\\*/"))
            ((and (not (and orig-macro-end
                            (<= (point) orig-macro-end)))
                  (js3-bfy-beginning-of-macro))
             (c-end-of-macro))
            (t
             (setq count (1- count))))))
  (point))


(defun js3-bfy-re-search-forward (regexp &optional bound noerror count)
  "Search forward, ignoring strings, cpp macros, and comments.
This function invokes `re-search-forward', but treats the buffer
as if strings, cpp macros, and comments have been removed.

If invoked while inside a macro, it treats the contents of the
macro as normal text."
  (unless count (setq count 1))
  (let ((saved-point (point))
        (search-fun
         (cond ((< count 0) (setq count (- count))
                #'js3-bfy-re-search-backward-inner)
               ((> count 0) #'js3-bfy-re-search-forward-inner)
               (t #'ignore))))
    (condition-case err
        (funcall search-fun regexp bound count)
      (search-failed
       (goto-char saved-point)
       (unless noerror
         (signal (car err) (cdr err)))))))


(defun js3-bfy-re-search-backward-inner (regexp &optional bound count)
  "Auxiliary function for `js3-bfy-re-search-backward'."
  (let ((parse)
        str-terminator
        (orig-macro-start
         (save-excursion
           (and (js3-bfy-beginning-of-macro)
                (point)))))
    (while (> count 0)
      (re-search-backward regexp bound)
      (when (and (> (point) (point-min))
                 (save-excursion (backward-char) (looking-at "/[/*]")))
        (forward-char))
      (setq parse (syntax-ppss))
      (cond ((setq str-terminator (nth 3 parse))
             (when (eq str-terminator t)
               (setq str-terminator ?/))
             (re-search-backward
              (concat "\\([^\\]\\|^\\)" (string str-terminator))
              (point-at-bol) t)
	     (when (not (string= "" (match-string 1)))
	       (forward-char)))
            ((nth 7 parse)
             (goto-char (nth 8 parse)))
            ((or (nth 4 parse)
                 (and (eq (char-before) ?/) (eq (char-after) ?*)))
             (re-search-backward "/\\*"))
            ((and (not (and orig-macro-start
                            (>= (point) orig-macro-start)))
                  (js3-bfy-beginning-of-macro)))
            (t
             (setq count (1- count))))))
  (point))


(defun js3-bfy-re-search-backward (regexp &optional bound noerror count)
  "Search backward, ignoring strings, preprocessor macros, and comments.

This function invokes `re-search-backward' but treats the buffer
as if strings, preprocessor macros, and comments have been
removed.

If invoked while inside a macro, treat the macro as normal text."
  (js3-bfy-re-search-forward regexp bound noerror (if count (- count) -1)))


(defun js3-bfy-looking-back (regexp)
  "This function returns t if regexp matches text before point, ending at point, and nil otherwise.

This function is similar to `looking-back' but ignores comments and strings"
  (save-excursion
    (let ((r (if (and (= ?\= (elt regexp (1- (length regexp))))
		      (= ?\\ (elt regexp (- (length regexp) 2))))
		 regexp
	       (concat regexp "\\="))))
      (numberp (js3-bfy-re-search-backward r (point-min) t)))))

(defun js3-bfy-looking-at (regexp)
  "This function returns t if regexp matches text after point, beginning at point, and nil otherwise.

This function is similar to `looking-at' but ignores comments and strings"
  (save-excursion
    (let ((r (if (and (= ?\= (elt regexp 1))
		      (= ?\\ (elt regexp 0)))
		 regexp
	       (concat "\\=" regexp))))
      (numberp (js3-bfy-re-search-forward r nil t)))))

(defun js3-bfy-looking-at-operator-p ()
  "Return non-nil if point is on a JavaScript operator, other than a comma."
  (save-match-data
    (and (looking-at js3-bfy-indent-operator-re)
         (or (not (= (following-char) ?\:))
             (save-excursion
               (and (js3-bfy-re-search-backward "[?:{]\\|\\_<case\\_>" nil t)
                    (= (following-char) ?\?)))))))


(defun js3-bfy-continued-expression-p ()
  "Return non-nil if the current line continues an expression."
  (save-excursion
    (back-to-indentation)
    (or (js3-bfy-looking-at-operator-p)
        (and (js3-bfy-re-search-backward "\n" nil t)
             (progn
               (skip-chars-backward " \t")
               (or (bobp) (backward-char))
               (and (> (point) (point-min))
                    (save-excursion (backward-char) (not (looking-at "[/*]/")))
                    (js3-bfy-looking-at-operator-p)
                    (and (progn (backward-char)
                                (not (looking-at "++\\|--\\|/[/*]"))))))))))


(defun js3-bfy-end-of-do-while-loop-p ()
  "Return non-nil if point is on the \"while\" of a do-while statement.
Otherwise, return nil.  A braceless do-while statement spanning
several lines requires that the start of the loop is indented to
the same column as the current line."
  (interactive)
  (save-excursion
    (save-match-data
      (when (looking-at "\\s-*\\_<while\\_>")
        (if (save-excursion
              (skip-chars-backward (concat js3-bfy-skip-newlines-re "}"))
              (looking-at (concat js3-bfy-skip-newlines-re "}")))
            (save-excursion
              (backward-list) (forward-symbol -1) (looking-at "\\_<do\\_>"))
          (js3-bfy-re-search-backward "\\_<do\\_>" (point-at-bol) t)
          (or (looking-at "\\_<do\\_>")
              (let ((saved-indent (current-indentation)))
                (while (and (js3-bfy-re-search-backward "^\\s-*\\_<" nil t)
                            (/= (current-indentation) saved-indent)))
                (and (looking-at "\\s-*\\_<do\\_>")
                     (not (js3-bfy-re-search-forward
                           "\\_<while\\_>" (point-at-eol) t))
                     (= (current-indentation) saved-indent)))))))))


(defun js3-bfy-backward-whitespace ()
  "Helper function for `js3-bfy-proper-indentation'.
Skip backwards over whitespace and comments."
  (let ((rv nil))
    (when (js3-bfy-looking-back "[ \t\n]")
      (setq rv t)
      (js3-bfy-re-search-backward (concat "[^ \t\n]" js3-bfy-skip-newlines-re)
				  (point-min) t)
      (forward-char))
    rv))


(defun js3-bfy-backward-sexp ()
  "Helper function for `js3-bfy-proper-indentation'.
Go backwards over matched braces, rather than whole expressions.
Only skip over strings while looking for braces.
Functionality does not exactly match backward-sexp."
  (let ((brackets 0)
	(rv nil))
    (while (js3-bfy-looking-back (concat "[]})]" js3-bfy-skip-newlines-re))
      (setq rv t)
      (js3-bfy-re-search-backward (concat "[]})]"
					  js3-bfy-skip-newlines-re)
				  (point-min) t)
      (cond
       ((= (following-char) ?\])
        (setq brackets (1+ brackets))
        (while (/= brackets 0)
          (js3-bfy-re-search-backward "[][]" (point-min) t)
          (cond
           ((= (following-char) ?\])
            (setq brackets (1+ brackets)))
           ((= (following-char) ?\[)
            (setq brackets (1- brackets))))))

       ((= (following-char) ?\})
        (setq brackets (1+ brackets))
        (while (/= brackets 0)
          (js3-bfy-re-search-backward "[}{]" (point-min) t)
          (cond
           ((= (following-char) ?\})
            (setq brackets (1+ brackets)))
           ((= (following-char) ?\{)
            (setq brackets (1- brackets))))))

       ((= (following-char) ?\))
        (setq brackets (1+ brackets))
        (while (/= brackets 0)
          (js3-bfy-re-search-backward "[)(]" (point-min) t)
          (cond
           ((= (following-char) ?\))
            (setq brackets (1+ brackets)))
           ((= (following-char) ?\()
            (setq brackets (1- brackets))))))))
    rv))


(defun js3-bfy-backward-clean ()
  "Helper function for `js3-bfy-proper-indentation'.
Calls js3-bfy-backward-sexp and js3-bfy-backward-whitespace until they are done."
  (let ((rv nil))
    (while (or (js3-bfy-backward-whitespace) (js3-bfy-backward-sexp))
      (setq rv t))
    rv))


(defun js3-bfy-ctrl-statement-indentation ()
  "Helper function for `js3-bfy-proper-indentation'.
Return the proper indentation of the current line if it starts
the body of a control statement without braces; otherwise, return
nil."
  (save-excursion
    (back-to-indentation)
    (when (save-excursion
            (and (not (eq (point-at-bol) (point-min)))
                 (not (= (following-char) ?\{))
                 (progn
                   (js3-bfy-re-search-backward "[[:graph:]]" nil t)
                   (or (eobp) (forward-char))
                   (when (= (char-before) ?\)) (backward-list))
                   (skip-syntax-backward " ")
                   (skip-syntax-backward "w_")
                   (looking-at js3-bfy-possibly-braceless-keyword-re))
                 (not (js3-bfy-end-of-do-while-loop-p))))
      (save-excursion
        (goto-char (match-beginning 0))
        (+ (current-indentation) js3-bfy-indent-level)))))

(defun js3-bfy-get-c-offset (symbol anchor)
  (let ((c-offsets-alist
         (list (cons 'c js3-bfy-comment-lineup-func))))
    (c-get-syntactic-indentation (list (cons symbol anchor)))))

(defun js3-bfy-back-offset (abs offset)
  "Helper function for `js3-bfy-proper-indentation'."
  (goto-char abs)
  (while (= (preceding-char) ?\ )
    (backward-char))
  (backward-char offset)
  (current-column))

(defun js3-bfy-back-offset-re (abs re)
  "Helper function for `js3-bfy-proper-indentation'."
  (goto-char abs)
  (js3-bfy-re-search-forward re nil t)
  (backward-char)
  (current-column))

(defun js3-bfy-proper-indentation (parse-status)
  "Return the proper indentation for the current line."
  (save-excursion
    (back-to-indentation)
    (let ((node (js3-bfy-node-at-point)))
      (if (not node)
	  0
	(let ((char (following-char))
	      (abs (js3-bfy-node-abs-pos node))
	      (type (js3-bfy-node-type node)))
	  (cond

	   ;;inside a multi-line comment
	   ((nth 4 parse-status)
	    (cond
	     ((= (char-after) ?*)
	      (goto-char abs)
	      (1+ (current-column)))
	     (t
	      (goto-char abs)
	      (if (not (looking-at "/\\*\\s-*\\S-"))
		  (current-column)
		(forward-char 2)
		(re-search-forward "\\S-" nil t)
		(1- (current-column))))))

	   ;;inside a string - indent to 0 since you can't do that.
	   ((nth 8 parse-status) 0)

	   ;;comma-first and operator-first
	   ((or
	     (= (following-char) ?\,)
	     (looking-at js3-bfy-indent-operator-first-re))
	    (cond
	     ;;bare statements
	     ((= type js3-bfy-VAR)
	      (goto-char abs)
	      (+ (current-column) 2))
	     ((= type js3-bfy-RETURN)
	      (goto-char abs)
	      (+ (current-column) 5))

	     ;;lists
	     ((= type js3-bfy-ARRAYLIT)
	      (js3-bfy-back-offset-re abs "[[]"))
	     ((= type js3-bfy-OBJECTLIT)
	      (js3-bfy-back-offset-re abs "{"))
	     ((= type js3-bfy-FUNCTION)
	      (js3-bfy-back-offset-re abs "("))
	     ((= type js3-bfy-CALL)
	      (js3-bfy-back-offset-re abs "("))

	     ;;operators
	     ((and (>= type 9)
		   (<= type 18)) ; binary operators
	      (js3-bfy-back-offset abs 1))
	     ((= type js3-bfy-COMMA)
	      (js3-bfy-back-offset abs 1))
	     ((= type js3-bfy-ASSIGN)
	      (js3-bfy-back-offset abs 1))
	     ((= type js3-bfy-HOOK)
	      (js3-bfy-back-offset abs 1))

	     ((= type js3-bfy-GETPROP) ; dot operator
	      (goto-char abs)
	      (if (js3-bfy-looking-at ".*\\..*")
		  (progn (js3-bfy-re-search-forward "\\." nil t)
			 (backward-char)
			 (current-column))
		(+ (current-column)
		   js3-bfy-expr-indent-offset js3-bfy-indent-level)))

	     ;; multi-char operators
	     ((and (>= type 19)
		   (<= type 24)) ; 2-char binary operators
	      (js3-bfy-back-offset abs 2))
	     ((or (= type js3-bfy-URSH)
		  (= type js3-bfy-SHEQ)
		  (= type js3-bfy-SHNE)) ;3-char binary operators
	      (js3-bfy-back-offset abs 3))
	     ((and (>= type 103)
		   (<= type 104)) ; logical and/or
	      (js3-bfy-back-offset abs 2))

	     ;;multi-char assignment
	     ((and (>= type 90)
		   (<= type 97)) ; assignment 2-char
	      (js3-bfy-back-offset abs 2))
	     ((and (>= type 98)
		   (<= type 99)) ; assignment 3-char
	      (js3-bfy-back-offset abs 3))
	     ((= type 100)       ; assignment 4-char
	      (js3-bfy-back-offset abs 4))

	     (t
	      (goto-char abs)
	      (+ (current-column) js3-bfy-indent-level
		 js3-bfy-expr-indent-offset))))

	   ;;indent control statement body without braces, if applicable
	   ((js3-bfy-ctrl-statement-indentation))

	   ;;c preprocessor - indent to 0
	   ((eq (char-after) ?#) 0)

	   ;;we're in a cpp macro - indent to 4 why not
	   ((save-excursion (js3-bfy-beginning-of-macro)) 4)

	   ;;inside a parenthetical grouping
	   ((nth 1 parse-status)
	    ;; A single closing paren/bracket should be indented at the
	    ;; same level as the opening statement.
	    (let ((same-indent-p (looking-at
				  "[]})]"))
		  (continued-expr-p (js3-bfy-continued-expression-p)))
	      (goto-char (nth 1 parse-status)) ; go to the opening char
	      (if (looking-at "[({[]\\s-*\\(/[/*]\\|$\\)")
		  (progn ; nothing following the opening paren/bracket
		    (skip-syntax-backward " ")
		    (when (eq (char-before) ?\)) (backward-list)) ;skip arg list
		    (if (and (not js3-bfy-consistent-level-indent-inner-bracket)
			     (js3-bfy-looking-back (concat
						"\\(:\\|,\\)"
						js3-bfy-skip-newlines-re
						"\\<function\\>"
						js3-bfy-skip-newlines-re)))
			(progn
			  (js3-bfy-re-search-backward (concat
						   "\\(:\\|,\\)"
						   js3-bfy-skip-newlines-re
						   "\\<function\\>"
						   js3-bfy-skip-newlines-re))
			  (js3-bfy-backward-clean)
			  (if (looking-back "[{[(,][^{[(,\n]*")
			      (progn
				(js3-bfy-re-search-backward "[{[(,][^{[(,\n]*")
				(forward-char)
				(js3-bfy-re-search-forward "[ \t]*"))
			    (progn
			      (js3-bfy-re-search-backward "^")
			      (back-to-indentation)
			      (while (\= (char-after) ?f)
				(forward-char)))))
		      (back-to-indentation))
		    (cond (same-indent-p
			   (current-column))
			  (continued-expr-p
			   (+ (current-column) (* 2 js3-bfy-indent-level)
			      js3-bfy-expr-indent-offset))
			  (t
			   (+ (current-column) js3-bfy-indent-level
			      (case (char-after (nth 1 parse-status))
				    (?\( js3-bfy-paren-indent-offset)
				    (?\[ js3-bfy-square-indent-offset)
				    (?\{ js3-bfy-curly-indent-offset))))))
		;; If there is something following the opening
		;; paren/bracket, everything else should be indented at
		;; the same level.
		(unless same-indent-p
		  (forward-char)
		  (skip-chars-forward " \t"))
		(current-column))))

	   ;;in a continued expression not handled by earlier cases
	   ((js3-bfy-continued-expression-p)
	    (+ js3-bfy-indent-level js3-bfy-expr-indent-offset))

	   ;;if none of these cases, then indent to 0
	   (t 0)))))))

(defun js3-bfy-indent-line ()
  "Indent the current line as JavaScript."
  (interactive)
  (save-restriction
    (widen)
    (let* ((parse-status
            (save-excursion (syntax-ppss (point-at-bol))))
           (offset (- (current-column) (current-indentation)))
	   (proper-indentation (js3-bfy-proper-indentation parse-status))
	   cur
	   node
	   type)
      (save-excursion
	(back-to-indentation)
	(setq node (js3-bfy-node-at-point))
	(setq type (js3-bfy-node-type node))
	(setq cur (current-column))
	(when (or (looking-at ",")
		  (looking-at js3-bfy-indent-operator-first-re))
	  (forward-char 2)
	  (setq node (js3-bfy-node-at-point))))
      (indent-line-to proper-indentation)
      (save-excursion
	(back-to-indentation)
	(if (or (= type js3-bfy-BLOCK)
		(looking-at "\\(}\\|)\\|]\\|\n\\)"))
	    (js3-bfy-node-update-len node (- proper-indentation cur))
	  (js3-bfy-node-update-pos node (- proper-indentation cur))))
      (when (> offset 0) (forward-char offset)))))

;;; js3-bfy-indent.el ends here
