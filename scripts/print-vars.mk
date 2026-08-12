# One rule, so that one Makefile can ask another what is in a variable.
#
#   make -C ../packages -f Makefile -f /abs/path/to/print-vars.mk print-ALL_PKGS
#
# It is loaded as a SECOND -f: the target Makefile is read first and entirely
# unmodified, and this adds a rule it does not have. The goal is named on the
# command line, so which makefile supplies the default target does not matter.
#
# WHY THIS EXISTS RATHER THAN A COPY OF THE ANSWER. images/Makefile needs to
# know what the packages tree contains, and every alternative is a second source
# of truth: a list of package names here rots the day a tier grows (which is
# what happened to the 69-name desktop list this replaced), and a list of TIER
# names rots the day a tier is added, because an enumeration only ever matches
# what its author could see. Asking `packages/Makefile` for `ALL_PKGS` -- the
# one line every chain already edits -- is the only form with nothing in it to
# fall out of date.
#
# The path must be ABSOLUTE. make chdirs for -C before it opens any -f, so a
# relative path here resolves against the wrong directory.
print-%:
	@echo $($*)
