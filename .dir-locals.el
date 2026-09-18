;;; Directory Local Variables. -*- no-byte-compile: t; -*-
;;; For more information see (info "(emacs) Directory Variables")

;; ecc is one package spread over many files.  A checker handed
;; ecc-render.el alone has no way to know that: it reads the file name
;; as the package name, and then every `ecc-' symbol in it looks like a
;; name from somewhere else.  This says which file the package is.
((emacs-lisp-mode . ((package-lint-main-file . "ecc.el"))))
