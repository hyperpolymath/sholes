;; SPDX-License-Identifier: MPL-2.0
;; SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
;;
;; guix.scm — rsr-template-repo as a Guix package.
;;
;;   guix build -f build/guix.scm          # installs the source tree to share/rsr-template-repo
;;   guix shell -D -f build/guix.scm       # the full development toolchain
;;
;; This is a SOURCE package, and says so: a hermetic compiled build needs this
;; repository's idris2 and zig dependencies packaged in Guix, which they are not
;; (Guix builds offline). The toolchain below is real — `guix shell -D -f build/guix.scm`
;; then `just setup` gives a working environment. See docs/SETUP.adoc §Guix.
(use-modules (guix packages) (guix gexp)
             (guix build-system copy)
             (gnu packages)
             ((guix licenses) #:prefix license:))

;; The repository root: this file sits at the root or in build/ (PROVISIONING-STANDARD §1).
(define %source-dir
  (let ((d (dirname (current-filename))))
    (if (string=? (basename d) "build") (dirname d) d)))
;; A spec may name an output ("rust:cargo"); plain specification->package cannot.
(define (spec->input spec)
  (call-with-values (lambda () (specification->package+output spec))
    (lambda (pkg out) (if (string=? out "out") pkg (list pkg out)))))

(define %ignored
  '(".git" "target" ".eval" "node_modules" "_build" "deps" "zig-out" ".zig-cache" "dist-newstyle"))

(package
  (name "rsr-template-repo")
  (version "0.1.0")
  (source (local-file %source-dir "rsr-template-repo-checkout"
                      #:recursive? #t
                      #:select? (lambda (file stat)
                                  (not (member (basename file) %ignored)))))
  (build-system copy-build-system)
  (arguments (list #:install-plan #~'(("." "share/rsr-template-repo/"))))
  (native-inputs (map spec->input (list "git" "bash" "coreutils" "nss-certs" "just" "mise"
                                        "shellcheck" "chez-scheme" "gmp" "gcc-toolchain" "zig")))
  (home-page "https://github.com/hyperpolymath/rsr-template-repo")
  (synopsis "Rhodium Standard Repository template")
  (description "The estate's repository template: the RSR layout, an Idris2 ABI
seam with a Zig FFI, CI gates, and the provisioning set (launcher, Justfile,
mise, Guix, setup and AI-assisted installation guides).")
  (license license:mpl2.0))
