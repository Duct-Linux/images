# legacy/ — the original single-pass build scripts

These are the scripts Duct started from, kept for reference. **Nothing builds
them.** No Makefile, workflow or Dockerfile refers to this directory; the
working bootstrap is `images/toolchain/` plus the Dockerfiles one level up.

They are not a smaller version of the current build. They are a different and
weaker approach — a single native pass that compiles against the host's
toolchain and headers, where the current bootstrap does the LFS two-pass cross
build precisely so nothing of the host survives into the result.

If you ever revive them, these are the defects already known, so they do not
have to be rediscovered.

## Correctness

**The download cache verifies nothing.** `check_download_cache`
(`src/common.sh:41`) decides a cached file is good if a sidecar `.url` file
mentions the URL. A truncated download, a corrupted file or a substituted
tarball all pass — the content is never hashed. There is no sha256 anywhere in
this tree. The current pipeline pins every source by digest in
`packages/pkgs/versions.env` and refuses to unpack anything that does not match.

**The cache check is a substring match.** `grep -q $url` (`src/common.sh:46`) is
unquoted and unanchored, and a URL is full of regex metacharacters. `.` matches
any character, and one URL that is a substring of another is a hit.

**`ls` is parsed to find source directories** — `$(ls -d $WORK_DIR/glibc/glibc-*)`
(`src/01_glibc.sh:14`, and the same line in every other numbered script). This
breaks on any path containing a space, and silently yields two paths in one
variable if a previous run left an older version behind. Nothing cleans
`$WORK_DIR` between runs, and `extract_source` untars into an existing directory,
so leftovers accumulate.

**gcc is not built.** `src/04_gcc.sh` is commented out in `src/build.sh:12`, so
a completed run produces a rootfs with no compiler — it cannot rebuild itself,
which is the property the current images are built to have.

## Portability

**x86_64 only.** `TARGET=x86_64-duct-linux-gnu` is hardcoded
(`src/common.sh:62`), carrying the comment "This one probably needs
adjustments". It does. Duct now builds for x86_64 and aarch64 from the same
recipes.

**Job count is Linux-specific and unguarded.** `NUM_CORES` comes from
`/proc/cpuinfo` (`src/common.sh:58`), and `NUM_JOBS=$((NUM_CORES * JOB_FACTOR))`
(`:59`) is a shell syntax error when `JOB_FACTOR` is unset — which is what
happens whenever `.config` is missing or incomplete, since `read_property`
returns an empty string rather than failing.

## Shell hygiene

**`read_property` trims with `xargs`** (`src/common.sh:18`), which does not trim
whitespace so much as re-parse the value: quotes are consumed, backslashes eaten
and internal whitespace collapsed. A `CFLAGS` containing quoted arguments does
not survive it. The same line leaves `$prop_name` and `$CONFIG` unquoted.

**`set -e` does not reach the helpers.** `read_property` and `download_source`
are defined with `(` `)` rather than `{` `}` (`src/common.sh:13`, `:24`), so they
run in subshells and a failure inside one does not stop the caller.

**Every script assumes a working directory it does not set.** Each begins with
`# working directory is /` and then sources `./src/common.sh`, so running one
from anywhere else fails immediately.
