#!/bin/sh
# Can every package in the manifest actually be installed, right now?
#
#   preflight.sh <repo-url|repo-dir> <package>...
#
# `tape install` answers this too, forty minutes into an ISO build, one package
# at a time, with "no such package". This asks the index directly and answers
# for the whole manifest in a second, with a reason per name.
#
# THE INDEX IS THE AUTHORITY, and nothing else is. A package that has merged is
# not a package that can be installed -- CI seeds from the published set, and
# the gap between a merge and the publish that carries it has been measured at
# ten to forty minutes. A green `publish repository` run is not evidence
# either: publishes collect what is present rather than what their own trigger
# built, so one can complete without carrying your package and another can be
# reported cancelled having already inserted its rows.
#
# The index is fetched EVERY run and never cached. A stale repo.db is the same
# error one directory further away, and the command that lies looks exactly
# like the one that works.
#
# Four ways a name can fail, and they are not interchangeable:
#
#   ABSENT     no row at all. Not built, or not published yet.
#   PARTIAL    published for one architecture only. This is the one that reads
#              as success and then fails exactly one build -- the failure that
#              looks like an architecture-specific recipe bug and is not one.
#   WITHDRAWN  rows exist and every one of them has a deleted_at. Someone took
#              it out on purpose.
#   (arch=any) complete on its own, and a both-architectures rule applied
#              blindly calls it missing.

set -eu

usage() {
	echo "usage: preflight.sh <repo-url|repo-dir> <package>..." >&2
	exit 2
}

src=${1:-}
[ -n "$src" ] || usage
shift
[ $# -gt 0 ] || usage

command -v sqlite3 >/dev/null 2>&1 || {
	echo "preflight: sqlite3 is not installed, and this check cannot run without it." >&2
	echo "preflight: NOT a pass -- install sqlite3 or run the query by hand." >&2
	exit 2
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
db=$work/repo.db

case "$src" in
	http://*|https://*)
		echo "preflight: fetching $src/repo.db"
		curl -fsSL -o "$db" "$src/repo.db" || {
			echo "preflight: could not fetch $src/repo.db" >&2; exit 1; }
		;;
	*)
		[ -f "$src/repo.db" ] || { echo "preflight: no $src/repo.db" >&2; exit 1; }
		cp "$src/repo.db" "$db"
		;;
esac

# Everything installable, and everything withdrawn, in two queries rather than
# two per package: the manifest is a couple of hundred names and a query each
# would be a couple of hundred processes.
sqlite3 "$db" \
	"select name || ' ' || arch || ' ' || version || '-' || subversion
	 from packages where deleted_at is null;" >"$work/live" 2>/dev/null || {
	echo "preflight: could not read the index; is it a repo.db?" >&2; exit 1; }
sqlite3 "$db" \
	"select distinct name from packages where deleted_at is not null;" \
	>"$work/gone" 2>/dev/null || :

printf 'preflight: index fetched now, %s rows installable\n\n' \
	"$(grep -c . <"$work/live" || true)"

# One architecture, tested as a TOKEN. Written as a function rather than as a
# multi-part case pattern because the obvious pattern is wrong in a way that
# passes review: `*" aarch64 "*" x86_64 "*` against " aarch64 x86_64 " consumes
# the single space between the two names twice, never matches, and reports
# every correctly-published package as single-architecture. Caught by running
# it against the real index, where the answer was known.
has_arch() {
	case " $2 " in
		*" $1 "*) return 0 ;;
	esac
	return 1
}

bad=0
partial=0
absent=0
for pkg in "$@"; do
	arches=$(awk -v p="$pkg" '$1 == p { print $2 }' "$work/live" | sort -u | tr '\n' ' ')
	ver=$(awk -v p="$pkg" '$1 == p { print $3 }' "$work/live" | sort -u | tr '\n' ' ')

	if has_arch any "$arches"; then
		printf '  ok        %-27s %s(any)\n' "$pkg" "$ver"
	elif has_arch aarch64 "$arches" && has_arch x86_64 "$arches"; then
		printf '  ok        %-27s %s\n' "$pkg" "$ver"
	elif [ -z "${arches% }" ]; then
		if grep -qx "$pkg" "$work/gone" 2>/dev/null; then
			printf '  WITHDRAWN %-27s every row has a deleted_at\n' "$pkg"
		else
			printf '  ABSENT    %-27s no row in the index\n' "$pkg"
		fi
		absent=$((absent + 1)); bad=1
	else
		printf '  PARTIAL   %-27s %sonly -- the other build will fail\n' \
			"$pkg" "$arches"
		partial=$((partial + 1)); bad=1
	fi
done

echo
if [ "$bad" -eq 0 ]; then
	echo "preflight: every package in the manifest is installable on both architectures"
	exit 0
fi

printf 'preflight: %s absent or withdrawn, %s single-architecture\n' "$absent" "$partial"
echo "preflight: an ISO built now would fail at 'tape install' on the names above."
echo "preflight: if they merged recently, wait for a publish to COMPLETE and re-run"
echo "preflight: this -- merged is not published, and the gap is up to half an hour."
exit 1
