;;; js3-beautify-scan.el --- JavaScript scanner

;;; Commentary:

;; A port of Mozilla Rhino's scanner.
;; Corresponds to Rhino files Token.java and TokenStream.java.

;;; Code:


(eval-when-compile
  (require 'cl))

(defvar js3-beautify-tokens nil
  "List of all defined token names.")  ; initialized in `js3-beautify-token-names'

(defconst js3-beautify-token-names
  (let* ((names (make-vector js3-beautify-num-tokens -1))
         (case-fold-search nil)  ; only match js3-beautify-UPPER_CASE
         (syms (apropos-internal "^js3-beautify-\\(?:[A-Z_]+\\)")))
    (loop for sym in syms
          for i from 0
          do
          (unless (or (memq sym '(js3-beautify-EOF_CHAR js3-beautify-ERROR))
                      (not (boundp sym)))
            (aset names (symbol-value sym)         ; code, e.g. 152
                  (substring (symbol-name sym) 13)) ; name, e.g. "LET"
            (push sym js3-beautify-tokens)))
    names)
  "Vector mapping int values to token string names, sans `js3-beautify-' prefix.")

(defun js3-beautify-token-name (tok)
  "Return a string name for TOK, a token symbol or code.
Signals an error if it's not a recognized token."
  (let ((code tok))
    (if (symbolp tok)
        (setq code (symbol-value tok)))
    (if (eq code -1)
        "ERROR"
      (if (and (numberp code)
               (not (minusp code))
               (< code js3-beautify-num-tokens))
          (aref js3-beautify-token-names code)
        (error "Invalid token: %s" code)))))

(defsubst js3-beautify-token-sym (tok)
  "Return symbol for TOK given its code, e.g. 'js3-beautify-LP for code 86."
  (intern (js3-beautify-token-name tok)))

(defconst js3-beautify-token-codes
  (let ((table (make-hash-table :test 'eq :size 256)))
    (loop for name across js3-beautify-token-names
          for sym = (intern (concat "js3-beautify-" name))
          do
          (puthash sym (symbol-value sym) table))
    ;; clean up a few that are "wrong" in Rhino's token codes
    (puthash 'js3-beautify-DELETE js3-beautify-DELPROP table)
    table)
  "Hashtable mapping token symbols to their bytecodes.")

(defsubst js3-beautify-token-code (sym)
  "Return code for token symbol SYM, e.g. 86 for 'js3-beautify-LP."
  (or (gethash sym js3-beautify-token-codes)
      (error "Invalid token symbol: %s " sym)))  ; signal code bug

(defsubst js3-beautify-report-scan-error (msg &optional no-throw beg len)
  (setq js3-beautify-token-end js3-beautify-ts-cursor)
  (js3-beautify-report-error msg nil
                    (or beg js3-beautify-token-beg)
                    (or len (- js3-beautify-token-end js3-beautify-token-beg)))
  (unless no-throw
    (throw 'return js3-beautify-ERROR)))

(defsubst js3-beautify-get-string-from-buffer ()
  "Reverse the char accumulator and return it as a string."
  (setq js3-beautify-token-end js3-beautify-ts-cursor)
  (if js3-beautify-ts-string-buffer
      (apply #'string (nreverse js3-beautify-ts-string-buffer))
    ""))

;; TODO:  could potentially avoid a lot of consing by allocating a
;; char buffer the way Rhino does.
(defsubst js3-beautify-add-to-string (c)
  (push c js3-beautify-ts-string-buffer))

;; Note that when we "read" the end-of-file, we advance js3-beautify-ts-cursor
;; to (1+ (point-max)), which lets the scanner treat end-of-file like
;; any other character:  when it's not part of the current token, we
;; unget it, allowing it to be read again by the following call.
(defsubst js3-beautify-unget-char ()
  (decf js3-beautify-ts-cursor))

;; Rhino distinguishes \r and \n line endings.  We don't need to
;; because we only scan from Emacs buffers, which always use \n.
(defsubst js3-beautify-get-char ()
  "Read and return the next character from the input buffer.
Increments `js3-beautify-ts-lineno' if the return value is a newline char.
Updates `js3-beautify-ts-cursor' to the point after the returned char.
Returns `js3-beautify-EOF_CHAR' if we hit the end of the buffer.
Also updates `js3-beautify-ts-hit-eof' and `js3-beautify-ts-line-start' as needed."
  (let (c)
    ;; check for end of buffer
    (if (>= js3-beautify-ts-cursor (point-max))
        (setq js3-beautify-ts-hit-eof t
              js3-beautify-ts-cursor (1+ js3-beautify-ts-cursor)
              c js3-beautify-EOF_CHAR)  ; return value
      ;; otherwise read next char
      (setq c (char-before (incf js3-beautify-ts-cursor)))
      ;; if we read a newline, update counters
      (if (= c ?\n)
          (setq js3-beautify-ts-line-start js3-beautify-ts-cursor
                js3-beautify-ts-lineno (1+ js3-beautify-ts-lineno)))
      ;; TODO:  skip over format characters
      c)))

(defsubst js3-beautify-read-unicode-escape ()
  "Read a \\uNNNN sequence from the input.
Assumes the ?\ and ?u have already been read.
Returns the unicode character, or nil if it wasn't a valid character.
Doesn't change the values of any scanner variables."
  ;; I really wish I knew a better way to do this, but I can't
  ;; find the Emacs function that takes a 16-bit int and converts
  ;; it to a Unicode/utf-8 character.  So I basically eval it with (read).
  ;; Have to first check that it's 4 hex characters or it may stop
  ;; the read early.
  (ignore-errors
   (let ((s (buffer-substring-no-properties js3-beautify-ts-cursor
                                            (+ 4 js3-beautify-ts-cursor))))
     (if (string-match "[a-zA-Z0-9]\\{4\\}" s)
         (read (concat "?\\u" s))))))

(defsubst js3-beautify-match-char (test)
  "Consume and return next character if it matches TEST, a character.
Returns nil and consumes nothing if TEST is not the next character."
  (let ((c (js3-beautify-get-char)))
    (if (eq c test)
        t
      (js3-beautify-unget-char)
      nil)))

(defsubst js3-beautify-peek-char ()
  (prog1
      (js3-beautify-get-char)
    (js3-beautify-unget-char)))

(defsubst js3-beautify-java-identifier-start-p (c)
  (or
   (memq c '(?$ ?_))
   (char-is-uppercase c)
   (char-is-lowercase c)))

(defsubst js3-beautify-java-identifier-part-p (c)
  "Implementation of java.lang.Character.isJavaIdentifierPart()"
  ;; TODO:  make me Unicode-friendly.  See comments above.
  (or
   (memq c '(?$ ?_))
   (char-is-uppercase c)
   (char-is-lowercase c)
   (and (>= c ?0) (<= c ?9))))

(defsubst js3-beautify-alpha-p (c)
  (cond ((and (<= ?A c) (<= c ?Z)) t)
        ((and (<= ?a c) (<= c ?z)) t)
        (t nil)))

(defsubst js3-beautify-digit-p (c)
  (and (<= ?0 c) (<= c ?9)))

(defsubst js3-beautify-js-space-p (c)
  (if (<= c 127)
      (memq c '(#x20 #x9 #xB #xC #xD))
    (or
     (eq c #xA0)
     ;; TODO:  change this nil to check for Unicode space character
     nil)))

(defconst js3-beautify-eol-chars (list js3-beautify-EOF_CHAR ?\n ?\r))

(defsubst js3-beautify-skip-line ()
  "Skip to end of line"
  (let (c)
    (while (not (memq (setq c (js3-beautify-get-char)) js3-beautify-eol-chars)))
    (js3-beautify-unget-char)
    (setq js3-beautify-token-end js3-beautify-ts-cursor)))

(defun js3-beautify-init-scanner (&optional buf line)
  "Create token stream for BUF starting on LINE.
BUF defaults to current-buffer and line defaults to 1.

A buffer can only have one scanner active at a time, which yields
dramatically simpler code than using a defstruct.  If you need to
have simultaneous scanners in a buffer, copy the regions to scan
into temp buffers."
  (save-excursion
    (when buf
      (set-buffer buf))
    (setq js3-beautify-ts-dirty-line nil
          js3-beautify-ts-regexp-flags nil
          js3-beautify-ts-string ""
          js3-beautify-ts-number nil
          js3-beautify-ts-hit-eof nil
          js3-beautify-ts-line-start 0
          js3-beautify-ts-lineno (or line 1)
          js3-beautify-ts-line-end-char -1
          js3-beautify-ts-cursor (point-min)
          js3-beautify-ts-string-buffer nil)))

(defconst js3-beautify-keywords
  '(break
    case catch const continue
    debugger default delete do
    else enum
    false finally for function
    if in instanceof import
    let
    new null
    return
    switch
    this throw true try typeof
    var void
    while with
    yield))

;; Token names aren't exactly the same as the keywords, unfortunately.
;; E.g. enum isn't in the tokens, and delete is js3-beautify-DELPROP.
(defconst js3-beautify-kwd-tokens
  (let ((table (make-vector js3-beautify-num-tokens nil))
        (tokens
         (list js3-beautify-BREAK
               js3-beautify-CASE js3-beautify-CATCH js3-beautify-CONST js3-beautify-CONTINUE
               js3-beautify-DEBUGGER js3-beautify-DEFAULT js3-beautify-DELPROP js3-beautify-DO
               js3-beautify-ELSE
               js3-beautify-FALSE js3-beautify-FINALLY js3-beautify-FOR js3-beautify-FUNCTION
               js3-beautify-IF js3-beautify-IN js3-beautify-INSTANCEOF js3-beautify-IMPORT
               js3-beautify-LET
               js3-beautify-NEW js3-beautify-NULL
               js3-beautify-RETURN
               js3-beautify-SWITCH
               js3-beautify-THIS js3-beautify-THROW js3-beautify-TRUE js3-beautify-TRY js3-beautify-TYPEOF
               js3-beautify-VAR
               js3-beautify-WHILE js3-beautify-WITH
               js3-beautify-YIELD)))
    (dolist (i tokens)
      (aset table i t))
    (aset table js3-beautify-STRING t)
    (aset table js3-beautify-REGEXP t)
    (aset table js3-beautify-COMMENT t)
    (aset table js3-beautify-THIS t)
    (aset table js3-beautify-VOID t)
    (aset table js3-beautify-NULL t)
    (aset table js3-beautify-TRUE t)
    (aset table js3-beautify-FALSE t)
    table)
  "Vector whose values are non-nil for tokens that are keywords.")

(defconst js3-beautify-reserved-words
  '(abstract
    boolean byte
    char class
    double
    enum export extends
    final float
    goto
    implements import int interface
    long
    native
    package private protected public
    short static super synchronized
    throws transient
    volatile))

(defconst js3-beautify-keyword-names
  (let ((table (make-hash-table :test 'equal)))
    (loop for k in js3-beautify-keywords
          do (puthash
              (symbol-name k)                            ; instanceof
              (intern (concat "js3-beautify-"
                              (upcase (symbol-name k)))) ; js3-beautify-INSTANCEOF
              table))
    table)
  "JavaScript keywords by name, mapped to their symbols.")

(defconst js3-beautify-reserved-word-names
  (let ((table (make-hash-table :test 'equal)))
    (loop for k in js3-beautify-reserved-words
          do
          (puthash (symbol-name k) 'js3-beautify-RESERVED table))
    table)
  "JavaScript reserved words by name, mapped to 'js3-beautify-RESERVED.")

(defsubst js3-beautify-collect-string (buf)
  "Convert BUF, a list of chars, to a string.
Reverses BUF before converting."
  (cond
   ((stringp buf)
    buf)
   ((null buf)  ; for emacs21 compat
    "")
   (t
    (if buf
        (apply #'string (nreverse buf))
      ""))))

(defun js3-beautify-string-to-keyword (s)
  "Return token for S, a string, if S is a keyword or reserved word.
Returns a symbol such as 'js3-beautify-BREAK, or nil if not keyword/reserved."
  (or (gethash s js3-beautify-keyword-names)
      (gethash s js3-beautify-reserved-word-names)))

(defsubst js3-beautify-ts-set-char-token-bounds ()
  "Used when next token is one character."
  (setq js3-beautify-token-beg (1- js3-beautify-ts-cursor)
        js3-beautify-token-end js3-beautify-ts-cursor))

(defsubst js3-beautify-ts-return (token)
  "Return an N-character TOKEN from `js3-beautify-get-token'.
Updates `js3-beautify-token-end' accordingly."
  (setq js3-beautify-token-end js3-beautify-ts-cursor)
  (throw 'return token))

(defsubst js3-beautify-x-digit-to-int (c accumulator)
  "Build up a hex number.
If C is a hexadecimal digit, return ACCUMULATOR * 16 plus
corresponding number.  Otherwise return -1."
  (catch 'return
    (catch 'check
      ;; Use 0..9 < A..Z < a..z
      (cond
       ((<= c ?9)
        (decf c ?0)
        (if (<= 0 c)
            (throw 'check nil)))
       ((<= c ?F)
        (when (<= ?A c)
          (decf c (- ?A 10))
          (throw 'check nil)))
       ((<= c ?f)
        (when (<= ?a c)
          (decf c (- ?a 10))
          (throw 'check nil))))
      (throw 'return -1))
    (logior c (lsh accumulator 4))))

(defun js3-beautify-get-token ()
  "Return next JavaScript token, an int such as js3-beautify-RETURN."
  (let (c
        c1
        identifier-start
        is-unicode-escape-start
        contains-escape
        escape-val
        escape-start
        str
        result
        base
        is-integer
        quote-char
        val
        look-for-slash
        continue)
    (catch 'return
      (while t
        ;; Eat whitespace, possibly sensitive to newlines.
        (setq continue t)
        (while continue
          (setq c (js3-beautify-get-char))
          (cond
           ((eq c js3-beautify-EOF_CHAR)
            (js3-beautify-ts-set-char-token-bounds)
            (throw 'return js3-beautify-EOF))
           ((eq c ?\n)
            (js3-beautify-ts-set-char-token-bounds)
            (setq js3-beautify-ts-dirty-line nil)
            (throw 'return js3-beautify-EOL))
           ((not (js3-beautify-js-space-p c))
            (if (/= c ?-)               ; in case end of HTML comment
                (setq js3-beautify-ts-dirty-line t))
            (setq continue nil))))
        ;; Assume the token will be 1 char - fixed up below.
        (js3-beautify-ts-set-char-token-bounds)
        ;; identifier/keyword/instanceof?
        ;; watch out for starting with a <backslash>
        (cond
         ((eq c ?\\)
          (setq c (js3-beautify-get-char))
          (if (eq c ?u)
              (setq identifier-start t
                    is-unicode-escape-start t
                    js3-beautify-ts-string-buffer nil)
            (setq identifier-start nil)
            (js3-beautify-unget-char)
            (setq c ?\\)))
         (t
          (when (setq identifier-start (js3-beautify-java-identifier-start-p c))
            (setq js3-beautify-ts-string-buffer nil)
            (js3-beautify-add-to-string c))))
        (when identifier-start
          (setq contains-escape is-unicode-escape-start)
          (catch 'break
            (while t
              (if is-unicode-escape-start
                  ;; strictly speaking we should probably push-back
                  ;; all the bad characters if the <backslash>uXXXX
                  ;; sequence is malformed. But since there isn't a
                  ;; correct context(is there?) for a bad Unicode
                  ;; escape sequence in an identifier, we can report
                  ;; an error here.
                  (progn
                    (setq escape-val 0)
                    (dotimes (i 4)
                      (setq c (js3-beautify-get-char)
                            escape-val (js3-beautify-x-digit-to-int c escape-val))
                      ;; Next check takes care of c < 0 and bad escape
                      (if (minusp escape-val)
                          (throw 'break nil)))
                    (if (minusp escape-val)
                        (js3-beautify-report-scan-error "msg.invalid.escape" t))
                    (js3-beautify-add-to-string escape-val)
                    (setq is-unicode-escape-start nil))
                (setq c (js3-beautify-get-char))
                (cond
                 ((eq c ?\\)
                  (setq c (js3-beautify-get-char))
                  (if (eq c ?u)
                      (setq is-unicode-escape-start t
                            contains-escape t)
                    (js3-beautify-report-scan-error "msg.illegal.character" t)))
                 (t
                  (if (or (eq c js3-beautify-EOF_CHAR)
                          (not (js3-beautify-java-identifier-part-p c)))
                      (throw 'break nil))
                  (js3-beautify-add-to-string c))))))
          (js3-beautify-unget-char)
          (setq str (js3-beautify-get-string-from-buffer))
          (unless contains-escape
            ;; OPT we shouldn't have to make a string (object!) to
            ;; check if it's a keyword.
            ;; Return the corresponding token if it's a keyword
            (when (setq result (js3-beautify-string-to-keyword str))
              (if (and (< js3-beautify-language-version 170)
                       (memq result '(js3-beautify-LET js3-beautify-YIELD)))
                  ;; LET and YIELD are tokens only in 1.7 and later
                  (setq result 'js3-beautify-NAME))
              (if (neq result 'js3-beautify-RESERVED)
                  (throw 'return (js3-beautify-token-code result)))
              (js3-beautify-report-warning "msg.reserved.keyword" str)))
          ;; If we want to intern these as Rhino does, just use (intern str)
          (setq js3-beautify-ts-string str)
          (throw 'return js3-beautify-NAME))     ; end identifier/kwd check
        ;; is it a number?
        (when (or (js3-beautify-digit-p c)
                  (and (eq c ?.) (js3-beautify-digit-p (js3-beautify-peek-char))))
          (setq js3-beautify-ts-string-buffer nil
                base 10)
          (when (eq c ?0)
            (setq c (js3-beautify-get-char))
            (cond
             ((or (eq c ?x) (eq c ?X))
              (setq base 16)
              (setq c (js3-beautify-get-char)))
             ((js3-beautify-digit-p c)
              (setq base 8))
             (t
              (js3-beautify-add-to-string ?0))))
          (if (eq base 16)
              (while (<= 0 (js3-beautify-x-digit-to-int c 0))
                (js3-beautify-add-to-string c)
                (setq c (js3-beautify-get-char)))
            (while (and (<= ?0 c) (<= c ?9))
              ;; We permit 08 and 09 as decimal numbers, which
              ;; makes our behavior a superset of the ECMA
              ;; numeric grammar.  We might not always be so
              ;; permissive, so we warn about it.
              (when (and (eq base 8) (>= c ?8))
                (js3-beautify-report-warning "msg.bad.octal.literal"
                                    (if (eq c ?8) "8" "9"))
                (setq base 10))
              (js3-beautify-add-to-string c)
              (setq c (js3-beautify-get-char))))
          (setq is-integer t)
          (when (and (eq base 10) (memq c '(?. ?e ?E)))
            (setq is-integer nil)
            (when (eq c ?.)
              (loop do
                    (js3-beautify-add-to-string c)
                    (setq c (js3-beautify-get-char))
                    while (js3-beautify-digit-p c)))
            (when (memq c '(?e ?E))
              (js3-beautify-add-to-string c)
              (setq c (js3-beautify-get-char))
              (when (memq c '(?+ ?-))
                (js3-beautify-add-to-string c)
                (setq c (js3-beautify-get-char)))
              (unless (js3-beautify-digit-p c)
                (js3-beautify-report-scan-error "msg.missing.exponent" t))
              (loop do
                    (js3-beautify-add-to-string c)
                    (setq c (js3-beautify-get-char))
                    while (js3-beautify-digit-p c))))
          (js3-beautify-unget-char)
          (setq js3-beautify-ts-string (js3-beautify-get-string-from-buffer)
                js3-beautify-ts-number
                (if (and (eq base 10) (not is-integer))
                    (string-to-number js3-beautify-ts-string)
                  ;; TODO:  call runtime number-parser.  Some of it is in
                  ;; js3-beautify-util.el, but I need to port ScriptRuntime.stringToNumber.
                  (string-to-number js3-beautify-ts-string)))
          (throw 'return js3-beautify-NUMBER))
        ;; is it a string?
        (when (memq c '(?\" ?\'))
          ;; We attempt to accumulate a string the fast way, by
          ;; building it directly out of the reader.  But if there
          ;; are any escaped characters in the string, we revert to
          ;; building it out of a string buffer.
          (setq quote-char c
                js3-beautify-ts-string-buffer nil
                c (js3-beautify-get-char))
          (catch 'break
            (while (/= c quote-char)
              (catch 'continue
                (when (or (eq c ?\n) (eq c js3-beautify-EOF_CHAR))
                  (js3-beautify-unget-char)
                  (setq js3-beautify-token-end js3-beautify-ts-cursor)
                  (js3-beautify-report-error "msg.unterminated.string.lit")
                  (throw 'return js3-beautify-STRING))
                (when (eq c ?\\)
                  ;; We've hit an escaped character
                  (setq c (js3-beautify-get-char))
                  (case c
                        (?b (setq c ?\b))
                        (?f (setq c ?\f))
                        (?n (setq c ?\n))
                        (?r (setq c ?\r))
                        (?t (setq c ?\t))
                        (?v (setq c ?\v))
                        (?u
                         (setq c1 (js3-beautify-read-unicode-escape))
                         (if js3-beautify-parse-ide-mode
                             (if c1
                                 (progn
                                   ;; just copy the string in IDE-mode
                                   (js3-beautify-add-to-string ?\\)
                                   (js3-beautify-add-to-string ?u)
                                   (dotimes (i 3)
                                     (js3-beautify-add-to-string (js3-beautify-get-char)))
                                   (setq c (js3-beautify-get-char))) ; added at end of loop
                               ;; flag it as an invalid escape
                               (js3-beautify-report-warning "msg.invalid.escape"
                                                   nil (- js3-beautify-ts-cursor 2) 6))
                           ;; Get 4 hex digits; if the u escape is not
                           ;; followed by 4 hex digits, use 'u' + the
                           ;; literal character sequence that follows.
                           (js3-beautify-add-to-string ?u)
                           (setq escape-val 0)
                           (dotimes (i 4)
                             (setq c (js3-beautify-get-char)
                                   escape-val (js3-beautify-x-digit-to-int c escape-val))
                             (if (minusp escape-val)
                                 (throw 'continue nil))
                             (js3-beautify-add-to-string c))
                           ;; prepare for replace of stored 'u' sequence by escape value
                           (setq js3-beautify-ts-string-buffer (nthcdr 5 js3-beautify-ts-string-buffer)
                                 c escape-val)))
                        (?x
                         ;; Get 2 hex digits, defaulting to 'x'+literal
                         ;; sequence, as above.
                         (setq c (js3-beautify-get-char)
                               escape-val (js3-beautify-x-digit-to-int c 0))
                         (if (minusp escape-val)
                             (progn
                               (js3-beautify-add-to-string ?x)
                               (throw 'continue nil))
                           (setq c1 c
                                 c (js3-beautify-get-char)
                                 escape-val (js3-beautify-x-digit-to-int c escape-val))
                           (if (minusp escape-val)
                               (progn
                                 (js3-beautify-add-to-string ?x)
                                 (js3-beautify-add-to-string c1)
                                 (throw 'continue nil))
                             ;; got 2 hex digits
                             (setq c escape-val))))
                        (?\n
                         ;; Remove line terminator after escape to follow
                         ;; SpiderMonkey and C/C++
                         (setq c (js3-beautify-get-char))
                         (throw 'continue nil))
                        (t
                         (when (and (<= ?0 c) (< c ?8))
                           (setq val (- c ?0)
                                 c (js3-beautify-get-char))
                           (when (and (<= ?0 c) (< c ?8))
                             (setq val (- (+ (* 8 val) c) ?0)
                                   c (js3-beautify-get-char))
                             (when (and (<= ?0 c)
                                        (< c ?8)
                                        (< val #o37))
                               ;; c is 3rd char of octal sequence only
                               ;; if the resulting val <= 0377
                               (setq val (- (+ (* 8 val) c) ?0)
                                     c (js3-beautify-get-char))))
                           (js3-beautify-unget-char)
                           (setq c val)))))
                (js3-beautify-add-to-string c)
                (setq c (js3-beautify-get-char)))))
          (setq js3-beautify-ts-string (js3-beautify-get-string-from-buffer))
          (throw 'return js3-beautify-STRING))
        (case c
              (?\;
               (throw 'return js3-beautify-SEMI))
              (?\[
               (throw 'return js3-beautify-LB))
              (?\]
               (throw 'return js3-beautify-RB))
              (?{
               (throw 'return js3-beautify-LC))
              (?}
               (throw 'return js3-beautify-RC))
              (?\(
               (throw 'return js3-beautify-LP))
              (?\)
               (throw 'return js3-beautify-RP))
              (?,
               (throw 'return js3-beautify-COMMA))
              (??
               (throw 'return js3-beautify-HOOK))
              (?:
	       (throw 'return js3-beautify-COLON))
              (?.
	       (throw 'return js3-beautify-DOT))
              (?|
               (if (js3-beautify-match-char ?|)
                   (throw 'return js3-beautify-OR)
                 (if (js3-beautify-match-char ?=)
                     (js3-beautify-ts-return js3-beautify-ASSIGN_BITOR)
                   (throw 'return js3-beautify-BITOR))))
              (?^
               (if (js3-beautify-match-char ?=)
                   (js3-beautify-ts-return js3-beautify-ASSIGN_BITOR)
                 (throw 'return js3-beautify-BITXOR)))
              (?&
               (if (js3-beautify-match-char ?&)
                   (throw 'return js3-beautify-AND)
                 (if (js3-beautify-match-char ?=)
                     (js3-beautify-ts-return js3-beautify-ASSIGN_BITAND)
                   (throw 'return js3-beautify-BITAND))))
              (?=
               (if (js3-beautify-match-char ?=)
                   (if (js3-beautify-match-char ?=)
                       (js3-beautify-ts-return js3-beautify-SHEQ)
                     (throw 'return js3-beautify-EQ))
                 (throw 'return js3-beautify-ASSIGN)))
              (?!
               (if (js3-beautify-match-char ?=)
                   (if (js3-beautify-match-char ?=)
                       (js3-beautify-ts-return js3-beautify-SHNE)
                     (js3-beautify-ts-return js3-beautify-NE))
                 (throw 'return js3-beautify-NOT)))
              (?<
               ;; NB:treat HTML begin-comment as comment-till-eol
               (when (js3-beautify-match-char ?!)
                 (when (js3-beautify-match-char ?-)
                   (when (js3-beautify-match-char ?-)
                     (js3-beautify-skip-line)
                     (setq js3-beautify-ts-comment-type 'html)
                     (throw 'return js3-beautify-COMMENT)))
                 (js3-beautify-unget-char))
               (if (js3-beautify-match-char ?<)
                   (if (js3-beautify-match-char ?=)
                       (js3-beautify-ts-return js3-beautify-ASSIGN_LSH)
                     (js3-beautify-ts-return js3-beautify-LSH))
                 (if (js3-beautify-match-char ?=)
                     (js3-beautify-ts-return js3-beautify-LE)
                   (throw 'return js3-beautify-LT))))
              (?>
               (if (js3-beautify-match-char ?>)
                   (if (js3-beautify-match-char ?>)
                       (if (js3-beautify-match-char ?=)
                           (js3-beautify-ts-return js3-beautify-ASSIGN_URSH)
                         (js3-beautify-ts-return js3-beautify-URSH))
                     (if (js3-beautify-match-char ?=)
                         (js3-beautify-ts-return js3-beautify-ASSIGN_RSH)
                       (js3-beautify-ts-return js3-beautify-RSH)))
                 (if (js3-beautify-match-char ?=)
                     (js3-beautify-ts-return js3-beautify-GE)
                   (throw 'return js3-beautify-GT))))
              (?*
               (if (js3-beautify-match-char ?=)
                   (js3-beautify-ts-return js3-beautify-ASSIGN_MUL)
                 (throw 'return js3-beautify-MUL)))
              (?/
               ;; is it a // comment?
               (when (js3-beautify-match-char ?/)
                 (setq js3-beautify-token-beg (- js3-beautify-ts-cursor 2))
                 (js3-beautify-skip-line)
                 (setq js3-beautify-ts-comment-type 'line)
                 (incf js3-beautify-token-end)
                 (throw 'return js3-beautify-COMMENT))
               ;; is it a /* comment?
               (when (js3-beautify-match-char ?*)
                 (setq look-for-slash nil
                       js3-beautify-token-beg (- js3-beautify-ts-cursor 2)
                       js3-beautify-ts-comment-type
                       (if (js3-beautify-match-char ?*)
                           (progn
                             (setq look-for-slash t)
                             'jsdoc)
                         'block))
                 (while t
                   (setq c (js3-beautify-get-char))
                   (cond
                    ((eq c js3-beautify-EOF_CHAR)
                     (setq js3-beautify-token-end (1- js3-beautify-ts-cursor))
                     (js3-beautify-report-error "msg.unterminated.comment")
                     (throw 'return js3-beautify-COMMENT))
                    ((eq c ?*)
                     (setq look-for-slash t))
                    ((eq c ?/)
                     (if look-for-slash
                         (js3-beautify-ts-return js3-beautify-COMMENT)))
                    (t
                     (setq look-for-slash nil
                           js3-beautify-token-end js3-beautify-ts-cursor)))))
               (if (js3-beautify-match-char ?=)
                   (js3-beautify-ts-return js3-beautify-ASSIGN_DIV)
                 (throw 'return js3-beautify-DIV)))
              (?#
               (when js3-beautify-skip-preprocessor-directives
                 (js3-beautify-skip-line)
                 (setq js3-beautify-ts-comment-type 'preprocessor
                       js3-beautify-token-end js3-beautify-ts-cursor)
                 (throw 'return js3-beautify-COMMENT))
               (throw 'return js3-beautify-ERROR))
              (?%
               (if (js3-beautify-match-char ?=)
                   (js3-beautify-ts-return js3-beautify-ASSIGN_MOD)
                 (throw 'return js3-beautify-MOD)))
              (?~
               (throw 'return js3-beautify-BITNOT))
              (?+
               (if (js3-beautify-match-char ?=)
                   (js3-beautify-ts-return js3-beautify-ASSIGN_ADD)
                 (if (js3-beautify-match-char ?+)
                     (js3-beautify-ts-return js3-beautify-INC)
                   (throw 'return js3-beautify-ADD))))
              (?-
               (cond
                ((js3-beautify-match-char ?=)
                 (setq c js3-beautify-ASSIGN_SUB))
                ((js3-beautify-match-char ?-)
                 (unless js3-beautify-ts-dirty-line
                   ;; treat HTML end-comment after possible whitespace
                   ;; after line start as comment-until-eol
                   (when (js3-beautify-match-char ?>)
                     (js3-beautify-skip-line)
                     (setq js3-beautify-ts-comment-type 'html)
                     (throw 'return js3-beautify-COMMENT)))
                 (setq c js3-beautify-DEC))
                (t
                 (setq c js3-beautify-SUB)))
               (setq js3-beautify-ts-dirty-line t)
               (js3-beautify-ts-return c))
              (otherwise
               (js3-beautify-report-scan-error "msg.illegal.character")))))))

(defun js3-beautify-read-regexp (start-token)
  "Called by parser when it gets / or /= in literal context."
  (let (c
        err
        in-class  ; inside a '[' .. ']' character-class
        flags
        (continue t))
    (setq js3-beautify-token-beg js3-beautify-ts-cursor
          js3-beautify-ts-string-buffer nil
          js3-beautify-ts-regexp-flags nil)
    (if (eq start-token js3-beautify-ASSIGN_DIV)
        ;; mis-scanned /=
        (js3-beautify-add-to-string ?=)
      (if (neq start-token js3-beautify-DIV)
          (error "failed assertion")))
    (while (and (not err)
                (or (/= (setq c (js3-beautify-get-char)) ?/)
                    in-class))
      (cond
       ((or (= c ?\n)
            (= c js3-beautify-EOF_CHAR))
        (setq js3-beautify-token-end (1- js3-beautify-ts-cursor)
              err t
              js3-beautify-ts-string (js3-beautify-collect-string js3-beautify-ts-string-buffer))
        (js3-beautify-report-error "msg.unterminated.re.lit"))
       (t (cond
           ((= c ?\\)
            (js3-beautify-add-to-string c)
            (setq c (js3-beautify-get-char)))
           ((= c ?\[)
            (setq in-class t))
           ((= c ?\])
            (setq in-class nil)))
          (js3-beautify-add-to-string c))))
    (unless err
      (while continue
        (cond
         ((js3-beautify-match-char ?g)
          (push ?g flags))
         ((js3-beautify-match-char ?i)
          (push ?i flags))
         ((js3-beautify-match-char ?m)
          (push ?m flags))
         (t
          (setq continue nil))))
      (if (js3-beautify-alpha-p (js3-beautify-peek-char))
          (js3-beautify-report-scan-error "msg.invalid.re.flag" t
                                 js3-beautify-ts-cursor 1))
      (setq js3-beautify-ts-string (js3-beautify-collect-string js3-beautify-ts-string-buffer)
            js3-beautify-ts-regexp-flags (js3-beautify-collect-string flags)
            js3-beautify-token-end js3-beautify-ts-cursor)
      ;; tell `parse-partial-sexp' to ignore this range of chars
      (js3-beautify-record-text-property
       js3-beautify-token-beg js3-beautify-token-end 'syntax-class '(2)))))

(defun js3-beautify-scanner-get-line ()
  "Return the text of the current scan line."
  (buffer-substring (point-at-bol) (point-at-eol)))

(provide 'js3-beautify-scan)

;;; js3-beautify-scan.el ends here
