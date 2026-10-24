#!/bin/sh
# Install kirakit into the Claude Code configuration directory.
#
# From a clone, files are symlinked back to the clone by default. When piped from curl,
# the repository is fetched into a temporary directory and files are copied.
#
# Output styles, skills, agents and CLAUDE.md are personalized from a profile: how Kira
# calls the user, the user's gender, the answer language and the assistant (git identity,
# signing key, GitHub account, Co-Authored-By trailers). The installer asks once (on the
# terminal, even when piped from curl) and saves the answers in $CLAUDE_DIR/.kirakit-profile
# for later runs.
#
# Usage: get-kira.sh [options] (see --help)
set -eu

KIRAKIT_REPO=${KIRAKIT_REPO:-https://github.com/Kodara-me/kirakit.git}
CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
# Set to the release tag in the copy attached to each GitHub release, so that it installs
# its own version.
KIRAKIT_VERSION=

dry_run=0
uninstall=0
mode=
only=
personas=
github_target=
work=
backup_dir=
build_dir=
reconfigure=0
installed=
originals_new=
removed=
profile=$CLAUDE_DIR/.kirakit-profile
manifest=$CLAUDE_DIR/.kirakit-manifest
originals=$CLAUDE_DIR/.kirakit-originals
permissions_record=$CLAUDE_DIR/.kirakit-permissions
# The launcher directory and the color scheme directory: resolved by resolve_launcher_dirs.
bin_dir=
konsole_dir=
profile_keys='name gender language assistant assistant_signing_key assistant_github co_author_trailer analyst analyst_github coder coder_signing_key coder_github'
nl='
'
tab=$(printf '\t')

log() {
	printf 'kirakit: %s\n' "$*"
}

die() {
	printf 'kirakit: error: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<EOF
Usage: get-kira.sh [options]

Options:
  --dry-run                  Print what would change, change nothing
  --name NAME                How Kira calls you
  --gender GENDER            male, female, nonbinary or unspecified
  --language LANGUAGE        Answer language, or auto to follow the conversation
  --assistant "NAME <EMAIL>" The assistant's git identity (its commits, and its trailer in yours)
  --assistant-signing-key PATH
                             The assistant's public SSH signing key (empty: it does not commit;
                             with a coder, the coder commits its work)
  --assistant-github LOGIN   The assistant's own GitHub account (empty: none)
  --co-author "NAME <EMAIL>" Same as --assistant, with Co-Authored-By trailers
  --no-co-author             Add no Co-Authored-By trailer to commits
  --analyst                  Add Iris, an analyst for ideas and specifications, to the team
  --no-analyst               No analyst: Kira writes ideas and specifications herself
  --analyst-github LOGIN     The analyst's own GitHub account (implies --analyst; empty: none)
  --coder "NAME <EMAIL>"     The coder's git identity, for Cleo (default: none)
  --coder-signing-key PATH   The coder's public SSH signing key (empty: none; the assistant
                             then commits her work)
  --coder-github LOGIN       The coder's own GitHub account (empty: none)
  --allow-releases           Let the assistant create releases and push tags without a prompt
  --no-allow-releases        Releases and tags stay behind a prompt (default)
  --complete-approved-prs    With a coder, let the assistant complete the coder's pull
                             requests it approved without your review
  --no-complete-approved-prs Every pull request waits for your review (default)
  --start-verified-specs     With an analyst and a coder, let the assistant verify the
                             analyst's specifications and move the verified ones to Ready
                             without you; only security questions are asked
  --no-start-verified-specs  Every specification waits in Specified for you (default)
  --default-style PERSONA    Output style selected in settings.json (default: kira-cozy)
  --assistant-style PERSONA  Style of the assistant launcher (default: the default style)
  --bin-dir DIR              Where the launchers go (default: ~/.local/bin, or bin/ in a
                             CLAUDE_CONFIG_DIR other than ~/.claude; saved)
  --color-scheme-dir DIR     Where the Konsole color schemes go (default: konsole/ in
                             XDG_DATA_HOME, or konsole/ in a CLAUDE_CONFIG_DIR other than
                             ~/.claude; saved)
  --reconfigure              Ask all profile questions again
  --persona NAME             Install only this persona (repeatable; default: all)
  --only COMPONENT           styles, claude (CLAUDE.md, rules, settings, agents, skills),
                             launchers (assistant, analyst, team, Konsole color schemes) or github
  --target DIR               Repository for --only github (default: the current one)
  --link                     Symlink files to the local clone (default from a clone)
  --copy                     Copy files (default without a clone)
  --uninstall                Remove what kirakit installed, launchers included
  -h, --help                 Show this help

Without --only, styles, claude and launchers are installed. The github component copies issue
and pull request templates, workflows and Copilot instructions into a repository's .github
directory.

Profile options are asked once and saved in \$CLAUDE_CONFIG_DIR/.kirakit-profile.

Environment:
  CLAUDE_CONFIG_DIR  Claude Code configuration directory (default: ~/.claude)
  XDG_DATA_HOME      Where the Konsole color schemes go without --color-scheme-dir, in konsole/
                     (default: ~/.local/share), when CLAUDE_CONFIG_DIR is ~/.claude or unset
  KIRAKIT_REPO       Repository fetched without a clone (default: $KIRAKIT_REPO)
  KIRAKIT_REF        Branch or tag fetched without a clone (default: the latest release)
EOF
}

# Run a command, or only print it in dry-run mode.
run() {
	if [ "$dry_run" -eq 1 ]; then
		printf '[dry-run] %s\n' "$*"
	else
		"$@"
	fi
}

cleanup() {
	if [ -n "$work" ]; then
		rm -rf -- "$work"
	fi
}

work_dir() {
	if [ -z "$work" ]; then
		work=$(mktemp -d "${TMPDIR:-/tmp}/kirakit.XXXXXX")
	fi
}

# backup PATH [ROOT [PREFIX] [cp]]: move PATH (or copy it, with "cp") into this run's
# backup directory, under PREFIX followed by PATH relative to ROOT. A path outside ROOT,
# such as a Konsole color scheme, is kept whole under "outside".
backup() {
	if [ -z "$backup_dir" ]; then
		# Never reuse the directory of an earlier run started within the same second.
		base=$CLAUDE_DIR/.kirakit-backups/$(date +%Y%m%d-%H%M%S)
		backup_dir=$base
		n=1
		while [ -e "$backup_dir" ]; do
			backup_dir=$base-$n
			n=$((n + 1))
		done
	fi
	case $1 in
	"${2:-$CLAUDE_DIR}"/*) rel=${1#"${2:-$CLAUDE_DIR}"/} ;;
	*) rel=outside$1 ;;
	esac
	dest=$backup_dir/${3-}$rel
	log "backup: $1 -> $dest"
	run mkdir -p "$(dirname -- "$dest")"
	if [ "${4-}" = cp ]; then
		run cp -p -- "$1" "$dest"
	else
		run mv -- "$1" "$dest"
	fi
}

# The branch or tag to fetch without a clone: KIRAKIT_REF, else the version this copy was
# released with, else the highest vX.Y.Z tag of the repository, else main.
resolve_ref() {
	if [ -n "${KIRAKIT_REF-}" ]; then
		printf '%s\n' "$KIRAKIT_REF"
		return
	fi
	if [ -n "$KIRAKIT_VERSION" ]; then
		printf '%s\n' "$KIRAKIT_VERSION"
		return
	fi
	latest=$(git ls-remote --tags --refs -- "$KIRAKIT_REPO" 'v*' 2>/dev/null | awk '
		{ tag = $2; sub("^refs/tags/", "", tag) }
		tag ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ {
			split(substr(tag, 2), part, ".")
			key = sprintf("%09d%09d%09d", part[1], part[2], part[3])
			if (key > best) { best = key; latest = tag }
		}
		END { if (latest != "") print latest }')
	printf '%s\n' "${latest:-main}"
}

# Whether TARGET is already an identical copy of SOURCE (a file or a directory).
same_copy() {
	if [ -L "$2" ]; then
		return 1
	elif [ -d "$1" ]; then
		[ -d "$2" ] && diff -r -q -- "$1" "$2" >/dev/null 2>&1
	else
		[ -f "$2" ] && cmp -s -- "$1" "$2"
	fi
}

# listed FILE PATH: whether PATH is the first field of a line of FILE.
listed() {
	[ -f "$1" ] && awk -F "$tab" -v path="$2" '$1 == path { found = 1; exit } END { exit !found }' "$1"
}

# install_file SOURCE TARGET [ROOT PREFIX]: link or copy SOURCE (a file or a directory) to
# TARGET, backing up anything else there. Targets in the configuration directory (no ROOT)
# are recorded in the manifest for --uninstall, with the backup of what was there before
# kirakit so that --uninstall can restore it.
install_file() {
	if [ -z "${3-}" ]; then
		installed="$installed$2$nl"
	fi
	if [ "$mode" = link ]; then
		if [ -L "$2" ] && [ "$(readlink "$2")" = "$1" ]; then
			log "up to date: $2"
			return
		fi
	elif same_copy "$1" "$2"; then
		log "up to date: $2"
		return
	fi

	if [ -e "$2" ] || [ -L "$2" ]; then
		backup "$2" "${3-}" "${4-}"
		if [ -z "${3-}" ] && ! listed "$manifest" "$2" && ! listed "$originals" "$2"; then
			originals_new="$originals_new$2$tab$dest$nl"
		fi
	fi
	run mkdir -p "$(dirname -- "$2")"
	if [ "$mode" = link ]; then
		log "link: $2 -> $1"
		run ln -s -- "$1" "$2"
	else
		log "copy: $1 -> $2"
		run cp -R -- "$1" "$2"
	fi
}

# Whether the value is empty or looks like "NAME <EMAIL>".
valid_co_author() {
	case $1 in
	'') return 0 ;;
	*'<'*'<'* | *'>'*'>'*) return 1 ;;
	?*' <'?*@?*'>') ;;
	*) return 1 ;;
	esac
	email=${1##*<}
	case $email in *[[:space:]]*) return 1 ;; esac
}

# Whether questions can be asked: true on a terminal, even when stdin is a pipe from curl.
# The subshell matters: a failed redirection on ":" would exit a POSIX shell.
can_prompt() {
	(: </dev/tty) 2>/dev/null
}

# ask QUESTION [DEFAULT]: print the answer, or DEFAULT when the answer is empty.
ask() {
	if [ -n "${2-}" ]; then
		printf '%s [%s] ' "$1" "$2" >/dev/tty
	else
		printf '%s ' "$1" >/dev/tty
	fi
	IFS= read -r answer </dev/tty || answer=
	printf '%s\n' "${answer:-${2-}}"
}

ask_gender() {
	case $1 in
	male) default=1 ;;
	female) default=2 ;;
	nonbinary) default=3 ;;
	*) default=4 ;;
	esac
	cat >/dev/tty <<EOF
How should Kira refer to you?
  1) male (he/him)
  2) female (she/her)
  3) non-binary (they/them)
  4) prefer not to say (they/them)
EOF
	while :; do
		case $(ask 'Choice' "$default") in
		1) echo male && return ;;
		2) echo female && return ;;
		3) echo nonbinary && return ;;
		4) echo unspecified && return ;;
		esac
	done
}

# ask_identity WHOSE DEFAULT_NAME CURRENT: ask for a git identity, such as WHOSE="Assistant's";
# print "NAME <EMAIL>", or nothing when no email is given.
ask_identity() {
	if [ -n "$3" ]; then
		current_name=${3% <*}
		current_email=${3##*<}
		current_email=${current_email%>}
	else
		current_name=$2
		current_email=
	fi
	name_answer=$(ask "$1 name" "$current_name")
	while :; do
		email_answer=$(ask "$1 email (empty: none)" "$current_email")
		if [ -z "$email_answer" ]; then
			echo
			return
		fi
		if valid_co_author "$name_answer <$email_answer>"; then
			printf '%s <%s>\n' "$name_answer" "$email_answer"
			return
		fi
		printf 'Expected an email address such as kira@example.com.\n' >/dev/tty
	done
}

# ask_signing_key WHOSE WHO CURRENT: ask for a public SSH signing key, such as WHOSE="Assistant's"
# and WHO="the assistant".
ask_signing_key() {
	ask "$1 public SSH signing key (empty: $2 does not commit as itself)" "$3"
}

# ask_github WHOSE CURRENT: ask for a GitHub login, such as WHOSE="Assistant's".
ask_github() {
	while :; do
		login=$(ask "$1 GitHub login (empty: none)" "$2")
		if valid_github "$login"; then
			printf '%s\n' "$login"
			return
		fi
		printf 'Expected a GitHub login (letters, digits and hyphens).\n' >/dev/tty
	done
}

ask_analyst() {
	while :; do
		case $(ask 'Add Iris, an analyst who clarifies ideas and writes specifications? (y/n)' "$1") in
		[Yy]*) echo yes && return ;;
		[Nn]*) echo no && return ;;
		esac
	done
}

ask_trailer() {
	while :; do
		case $(ask 'Add Co-Authored-By trailers to commit messages? (y/n)' "$1") in
		[Yy]*) echo yes && return ;;
		[Nn]*) echo no && return ;;
		esac
	done
}

# Whether the value is empty or a GitHub login.
valid_github() {
	case $1 in
	*[!A-Za-z0-9-]*) return 1 ;;
	esac
}

# Expand a leading "~/" so that the saved path does not depend on the shell.
expand_home() {
	# shellcheck disable=SC2088 # a literal "~/", expanded here
	case $1 in
	'~/'*) printf '%s/%s\n' "$HOME" "${1#'~/'}" ;;
	*) printf '%s\n' "$1" ;;
	esac
}

# resolve_launcher_dirs: the launcher directory and the color scheme directory, each from its
# option on this run, else the profile, else the default. given_bin_dir and
# given_color_scheme_dir hold a location given on this run or saved earlier, and are empty
# for a default, which is never saved in the profile. The default depends on the configuration
# directory: ~/.local/bin and the XDG data directory for ~/.claude, bin/ and konsole/ under the
# configuration directory for any other (scratch_launchers=1).
resolve_launcher_dirs() {
	given_bin_dir=${opt_bin_dir-${saved_bin_dir-}}
	given_color_scheme_dir=${opt_color_scheme_dir-${saved_color_scheme_dir-}}
	[ -z "$given_bin_dir" ] || given_bin_dir=$(expand_home "$given_bin_dir")
	[ -z "$given_color_scheme_dir" ] || given_color_scheme_dir=$(expand_home "$given_color_scheme_dir")
	default_bin_dir=$HOME/.local/bin
	default_konsole_dir=${XDG_DATA_HOME:-$HOME/.local/share}/konsole
	# Any configuration directory other than ~/.claude keeps its launchers under it by default,
	# so that a run aimed at a scratch directory never touches the user's own launchers.
	if [ "${CLAUDE_DIR%/}" = "$HOME/.claude" ]; then
		scratch_launchers=0
		bin_dir=${given_bin_dir:-$default_bin_dir}
		konsole_dir=${given_color_scheme_dir:-$default_konsole_dir}
	else
		scratch_launchers=1
		bin_dir=${given_bin_dir:-${CLAUDE_DIR%/}/bin}
		konsole_dir=${given_color_scheme_dir:-${CLAUDE_DIR%/}/konsole}
	fi
	case $bin_dir in
	/*) ;;
	*) die "the bin directory must be an absolute path: $bin_dir" ;;
	esac
	case $konsole_dir in
	/*) ;;
	*) die "the color scheme directory must be an absolute path: $konsole_dir" ;;
	esac
}

load_profile() {
	[ -f "$profile" ] || return 0
	while IFS='=' read -r key value; do
		case $key in
		name) saved_name=$value ;;
		gender) saved_gender=$value ;;
		language) saved_language=$value ;;
		co_author) saved_co_author=$value ;;
		assistant_name) saved_assistant_name=$value ;;
		assistant_email) saved_assistant_email=$value ;;
		assistant_signing_key) saved_assistant_signing_key=$value ;;
		assistant_github) saved_assistant_github=$value ;;
		co_author_trailer) saved_co_author_trailer=$value ;;
		analyst) saved_analyst=$value ;;
		analyst_github) saved_analyst_github=$value ;;
		coder) saved_coder=$value ;;
		coder_signing_key) saved_coder_signing_key=$value ;;
		coder_github) saved_coder_github=$value ;;
		allow_releases) saved_allow_releases=$value ;;
		complete_approved_prs) saved_complete_approved_prs=$value ;;
		start_verified_specs) saved_start_verified_specs=$value ;;
		style) saved_style=$value ;;
		assistant_style) saved_assistant_style=$value ;;
		bin_dir) saved_bin_dir=$value ;;
		color_scheme_dir) saved_color_scheme_dir=$value ;;
		esac
	done <"$profile"
	# Profiles before the analyst: the team had none, and the question is not asked again.
	if [ -z "${saved_analyst+set}" ]; then
		saved_analyst=no saved_analyst_github=
	fi
	# Profiles before the coder: the team had none, and the question is not asked again.
	if [ -z "${saved_coder+set}" ]; then
		saved_coder='' saved_coder_signing_key='' saved_coder_github=''
	fi
	if [ -n "${saved_assistant_name+set}" ]; then
		if [ -n "$saved_assistant_email" ]; then
			saved_assistant="$saved_assistant_name <$saved_assistant_email>"
		else
			saved_assistant=
		fi
	elif [ -n "${saved_co_author+set}" ]; then
		# Profiles before the assistant identity: the co-author was the assistant.
		saved_assistant=$saved_co_author
		if [ -n "$saved_co_author" ]; then
			saved_co_author_trailer=yes
		else
			saved_co_author_trailer=no
		fi
	fi
}

# should_ask KEY: whether to ask for KEY, i.e. it was not given as an option and either it
# is not saved yet or --reconfigure was passed.
should_ask() {
	eval "given=\${opt_$1+set} saved=\${saved_$1+set}"
	[ -z "$given" ] && { [ "$reconfigure" -eq 1 ] || [ -z "$saved" ]; }
}

# Resolve the profile from options, the saved profile, then questions.
setup_profile() {
	load_profile
	user_name=${opt_name-${saved_name-}}
	user_gender=${opt_gender-${saved_gender-unspecified}}
	user_language=${opt_language-${saved_language-auto}}
	assistant=${opt_assistant-${saved_assistant-}}
	assistant_signing_key=${opt_assistant_signing_key-${saved_assistant_signing_key-}}
	assistant_github=${opt_assistant_github-${saved_assistant_github-}}
	# An analyst's account means an analyst, unless --no-analyst says otherwise.
	if [ -n "${opt_analyst_github-}" ] && [ -z "${opt_analyst+set}" ]; then
		opt_analyst=yes
	fi
	analyst=${opt_analyst-${saved_analyst-no}}
	analyst_github=${opt_analyst_github-${saved_analyst_github-}}
	coder=${opt_coder-${saved_coder-}}
	coder_signing_key=${opt_coder_signing_key-${saved_coder_signing_key-}}
	coder_github=${opt_coder_github-${saved_coder_github-}}
	# R3: releases stay behind a prompt unless asked; not a question, an option.
	allow_releases=${opt_allow_releases-${saved_allow_releases:-no}}
	[ "$allow_releases" = yes ] || allow_releases=no
	# Pull requests wait for the user unless asked; not a question, an option.
	complete_approved_prs=${opt_complete_approved_prs-${saved_complete_approved_prs:-no}}
	[ "$complete_approved_prs" = yes ] || complete_approved_prs=no
	# Specifications wait for the user unless asked; not a question, an option.
	start_verified_specs=${opt_start_verified_specs-${saved_start_verified_specs:-no}}
	[ "$start_verified_specs" = yes ] || start_verified_specs=no
	if [ -n "$assistant" ]; then default_trailer=yes; else default_trailer=no; fi
	co_author_trailer=${opt_co_author_trailer-${saved_co_author_trailer-$default_trailer}}
	default_style=${opt_style-${saved_style:-kira-cozy}}
	# Empty: the assistant launcher follows the default style.
	assistant_style=${opt_assistant_style-${saved_assistant_style-}}
	resolve_launcher_dirs

	missing=
	for key in $profile_keys; do
		case $key in
		assistant_* | co_author_trailer)
			# Meaningless without an assistant identity, unless it is about to be asked.
			case "$missing " in *' assistant '*) ;; *) [ -n "$assistant" ] || continue ;; esac
			;;
		analyst_github)
			# Meaningless without an analyst, unless one is about to be asked for.
			case "$missing " in *' analyst '*) ;; *) [ "$analyst" = yes ] || continue ;; esac
			;;
		coder_*)
			# Meaningless without a coder identity, unless it is about to be asked.
			case "$missing " in *' coder '*) ;; *) [ -n "$coder" ] || continue ;; esac
			;;
		esac
		if should_ask "$key"; then
			missing="$missing $key"
		fi
	done
	if [ -n "$missing" ]; then
		if ! can_prompt; then
			log "no terminal to ask for:$missing; using defaults (see --help)"
			# The optional assistant and analyst values default to empty or no; only a missing required value
			# keeps the profile unsaved, so that a later run on a terminal asks for it.
			for key in $missing; do
				case $key in name | gender | language | assistant) no_save=1 ;; esac
			done
			missing=
		fi
	fi
	for key in $missing; do
		case $key in
		name) user_name=$(ask 'How should Kira call you?' "$user_name") ;;
		gender) user_gender=$(ask_gender "$user_gender") ;;
		language) user_language=$(ask 'Which language should Kira answer in? (auto follows the conversation)' "$user_language") ;;
		assistant) assistant=$(ask_identity "Assistant's" Kira "$assistant") ;;
		# The other assistant values mean nothing without an assistant identity.
		assistant_signing_key) [ -z "$assistant" ] || assistant_signing_key=$(ask_signing_key "Assistant's" 'the assistant' "$assistant_signing_key") ;;
		assistant_github) [ -z "$assistant" ] || assistant_github=$(ask_github "Assistant's" "$assistant_github") ;;
		co_author_trailer)
			if [ -n "$assistant" ]; then default_trailer=yes; else default_trailer=no; fi
			[ -z "$assistant" ] || co_author_trailer=$(ask_trailer "${saved_co_author_trailer-$default_trailer}")
			;;
		analyst) analyst=$(ask_analyst "$analyst") ;;
		# R8: the analyst never commits, so she has a GitHub account but no signing key.
		analyst_github) [ "$analyst" != yes ] || analyst_github=$(ask_github "Analyst's" "$analyst_github") ;;
		coder) coder=$(ask_identity "Coder's" Cleo "$coder") ;;
		# The other coder values mean nothing without a coder identity.
		coder_signing_key) [ -z "$coder" ] || coder_signing_key=$(ask_signing_key "Coder's" 'the coder' "$coder_signing_key") ;;
		coder_github) [ -z "$coder" ] || coder_github=$(ask_github "Coder's" "$coder_github") ;;
		esac
	done
	[ "$analyst" = yes ] || analyst=no analyst_github=
	if [ -z "$assistant" ]; then
		assistant_signing_key='' assistant_github='' co_author_trailer=no
	fi
	assistant_signing_key=$(expand_home "$assistant_signing_key")
	[ -n "$coder" ] || coder_signing_key='' coder_github=''
	coder_signing_key=$(expand_home "$coder_signing_key")
	if [ -n "$assistant" ]; then
		assistant_name=${assistant% <*}
		assistant_email=${assistant##*<}
		assistant_email=${assistant_email%>}
	else
		assistant_name='' assistant_email=''
	fi

	[ -z "${no_save-}" ] || return 0
	profile_text="name=$user_name${nl}gender=$user_gender${nl}language=$user_language${nl}assistant_name=$assistant_name${nl}assistant_email=$assistant_email${nl}assistant_signing_key=$assistant_signing_key${nl}assistant_github=$assistant_github${nl}co_author_trailer=$co_author_trailer${nl}analyst=$analyst${nl}analyst_github=$analyst_github${nl}coder=$coder${nl}coder_signing_key=$coder_signing_key${nl}coder_github=$coder_github${nl}allow_releases=$allow_releases${nl}complete_approved_prs=$complete_approved_prs${nl}start_verified_specs=$start_verified_specs${nl}style=$default_style${nl}assistant_style=$assistant_style"
	# Only a location given on this run or saved earlier, never the computed default.
	[ -z "$given_bin_dir" ] || profile_text="$profile_text${nl}bin_dir=$given_bin_dir"
	[ -z "$given_color_scheme_dir" ] || profile_text="$profile_text${nl}color_scheme_dir=$given_color_scheme_dir"
	if [ -f "$profile" ] && [ "$(cat "$profile")" = "$profile_text" ]; then
		return
	fi
	log "save profile: $profile"
	if [ "$dry_run" -eq 1 ]; then
		printf '[dry-run] write %s to %s\n' "$(printf '%s' "$profile_text" | tr '\n' ' ')" "$profile"
	else
		mkdir -p "$CLAUDE_DIR"
		printf '%s\n' "$profile_text" >"$profile"
	fi
}

# R8: warn about a signing key that is not there; the installer never creates one.
# check_signing_key WHO KEY, such as WHO="the assistant".
check_signing_key() {
	[ -n "$2" ] || return 0
	if [ ! -f "$2" ]; then
		log "warning: $1's signing key $2 does not exist; $1 cannot commit as itself until it does"
	elif [ ! -f "${2%.pub}" ]; then
		log "warning: no private key next to $2; $1 cannot sign with it"
	fi
}

# Build into the clone for symlinks, into a temporary directory otherwise, so that a dry
# run never writes outside it.
build() {
	if [ "$mode" = link ] && [ "$dry_run" -eq 0 ]; then
		build_dir=$src/dist
	else
		work_dir
		build_dir=$work/dist
	fi
	if [ "$co_author_trailer" = yes ]; then co_author=$assistant; else co_author=; fi
	if [ "$analyst" = yes ]; then analyst_flag=--analyst; else analyst_flag=; fi
	if [ "$complete_approved_prs" = yes ]; then complete_flag=--complete-approved-prs; else complete_flag=; fi
	# The build drops the setting without an analyst or without a coder.
	if [ "$start_verified_specs" = yes ]; then verified_flag=--start-verified-specs; else verified_flag=; fi
	# shellcheck disable=SC2086 # analyst_flag, complete_flag and verified_flag are empty or one word
	sh "$src/scripts/build.sh" -o "$build_dir" --name "$user_name" --gender "$user_gender" \
		--language "$user_language" --co-author "$co_author" --assistant "$assistant" \
		--assistant-signing-key "$assistant_signing_key" --assistant-github "$assistant_github" \
		$analyst_flag --analyst-github "$analyst_github" --assistant-style "${assistant_style:-$default_style}" \
		--coder "$coder" --coder-signing-key "$coder_signing_key" --coder-github "$coder_github" \
		$complete_flag $verified_flag >/dev/null || exit 1
}

# built PATH: where an installed file comes from; symlinks always point into the clone.
built() {
	if [ "$mode" = link ]; then
		printf '%s\n' "$src/dist/$1"
	else
		printf '%s\n' "$build_dir/$1"
	fi
}

# install_built PATH TARGET: install the built file PATH. A file the build left out (a
# template that renders to nothing for this profile) is not installed, and is removed if an
# earlier run installed it.
install_built() {
	if [ -e "$build_dir/$1" ]; then
		install_file "$(built "$1")" "$2"
	elif listed "$manifest" "$2"; then
		remove_installed "$2"
		removed="$removed$2$nl"
	fi
}

install_styles() {
	for file in "$src"/personas/*.md; do
		persona=$(basename "$file" .md)
		case $persona in _*) continue ;; esac
		if [ -n "$personas" ]; then
			case " $personas " in *" $persona "*) ;; *) continue ;; esac
		fi
		install_built "output-styles/$persona.md" "$CLAUDE_DIR/output-styles/$persona.md"
	done
	# Team members (team/NAME.md) have an output style and an agent; --persona is for Kira's.
	for file in "$src"/team/*.md; do
		[ -f "$file" ] || continue
		member=$(basename "$file" .md)
		install_built "output-styles/$member.md" "$CLAUDE_DIR/output-styles/$member.md"
	done
}

# The launchers and their Konsole color schemes. They live outside the configuration
# directory, but are recorded in the manifest like the rest, so that --uninstall removes them.
install_launchers() {
	launchers=
	log "launchers: $bin_dir"
	log "color schemes: $konsole_dir"
	for file in "$src"/launchers/*; do
		[ -f "$file" ] || continue
		launcher=$(basename "$file")
		install_built "bin/$launcher" "$bin_dir/$launcher"
		[ ! -e "$build_dir/bin/$launcher" ] || launchers="$launchers $launcher"
	done
	# Launchers an earlier run put in another bin directory.
	if [ -f "$manifest" ]; then
		while IFS= read -r path; do
			case $path in "$CLAUDE_DIR"/* | "$konsole_dir"/* | "$bin_dir"/*) continue ;; esac
			if in_default_launcher_location "$path"; then
				log "skip (default launcher location): $path"
				continue
			fi
			[ -f "$src/launchers/${path##*/}" ] || [ -f "$src/launchers/konsole/${path##*/}" ] || continue
			remove_installed "$path"
			removed="$removed$path$nl"
		done <"$manifest"
	fi
	for file in "$src"/launchers/konsole/*.colorscheme; do
		[ -f "$file" ] || continue
		scheme=$(basename "$file")
		install_built "konsole/$scheme" "$konsole_dir/$scheme"
	done
	case ":$PATH:" in
	*":$bin_dir:"*) ;;
	*) log "warning: $bin_dir is not on your PATH; add it to start the launchers by name" ;;
	esac
	for launcher in $launchers; do
		found=$(command -v "$launcher" 2>/dev/null) || continue
		[ "$found" = "$bin_dir/$launcher" ] ||
			log "warning: $found comes before $bin_dir/$launcher in your PATH"
	done
}

# in_default_launcher_location PATH: whether PATH is in a default launcher location while the
# launchers of this run go elsewhere, under a non-default configuration directory.
in_default_launcher_location() {
	[ "$scratch_launchers" -eq 1 ] || return 1
	case $1 in
	"$default_bin_dir"/* | "$default_konsole_dir"/*) return 0 ;;
	esac
	return 1
}

# Copy settings.json to the backups once per run, before its first change.
backup_settings() {
	if [ -f "$settings" ] && [ -z "${settings_backed_up-}" ]; then
		backup "$settings" "$CLAUDE_DIR" '' cp
		settings_backed_up=1
	fi
}

# insert_setting LINE FILE: print FILE with LINE as the first setting, or a new object.
insert_setting() {
	if [ ! -s "$2" ] || [ "$(tr -d ' \t\r\n' <"$2")" = '{}' ]; then
		printf '{\n  %s\n}\n' "$1"
		return
	fi
	awk -v line="$1" '
		!done && (i = index($0, "{")) {
			print substr($0, 1, i)
			print "  " line ","
			rest = substr($0, i + 1)
			if (rest ~ /[^ \t]/) print rest
			done = 1
			next
		}
		{ print }' "$2"
}

# R11: turn off the attribution Claude Code suggests, so the git rules are the only ones. An
# "attribution" setting the user wrote is left alone: without a JSON parser, it cannot be
# merged safely.
set_attribution() {
	settings=$CLAUDE_DIR/settings.json
	line='"attribution": {"commit": "", "pr": ""}'
	if [ -f "$settings" ]; then
		flat=$(tr -d ' \t\r\n' <"$settings")
		case $flat in
		*'"attribution":{"commit":"","pr":""}'* | *'"attribution":{"pr":"","commit":""}'*)
			log "up to date: $settings (attribution)"
			return
			;;
		*'"attribution":'*)
			log "warning: $settings already sets \"attribution\"; left unchanged. For the git rules alone to apply, set it by hand to: $line"
			return
			;;
		esac
	fi
	work_dir
	insert_setting "$line" "$settings" >"$work/settings.json"
	backup_settings
	log "set attribution: commit and pr off in $settings"
	if [ "$dry_run" -eq 0 ]; then
		mkdir -p "$CLAUDE_DIR"
		# Write in place to keep the file's permissions and any symlink.
		cat "$work/settings.json" >"$settings"
	fi
}

# Set "outputStyle" in settings.json to the default style, leaving every other setting as it
# is: Claude Code writes to this file too, so it is edited in place, never replaced.
set_output_style() {
	settings=$CLAUDE_DIR/settings.json
	value=$(sed -n 's/^name: //p' "$build_dir/output-styles/$default_style.md" | head -n 1)
	case $value in
	'' | *'"'* | *\\*) die "cannot use the name of $default_style as outputStyle: $value" ;;
	esac
	line="\"outputStyle\": \"$value\""
	if [ -f "$settings" ] && grep -qF "$line" "$settings"; then
		log "up to date: $settings (outputStyle)"
		return
	fi

	work_dir
	new=$work/settings.json
	if [ -s "$settings" ] && grep -q '"outputStyle"[[:space:]]*:' "$settings"; then
		escaped=$(printf '%s\n' "$line" | sed 's/[&|\\]/\\&/g')
		sed "s|\"outputStyle\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|$escaped|" "$settings" >"$new"
	else
		insert_setting "$line" "$settings" >"$new"
	fi

	backup_settings
	log "set outputStyle: $value in $settings"
	if [ "$dry_run" -eq 0 ]; then
		mkdir -p "$CLAUDE_DIR"
		# Write in place to keep the file's permissions and any symlink.
		cat "$new" >"$settings"
	fi
}

# permission_rules: print the permission rules the members' GitHub accounts need, one per
# line, without duplicates: a rule several members need is listed once (#67 R1, R2, R3;
# #79 R25, R27).
permission_rules() {
	{
		if [ -n "$assistant_github" ]; then
			gh="GH_TOKEN=\$(gh auth token --user $assistant_github) gh"
			for command in 'issue create' 'issue edit' 'issue comment' 'issue close' \
				'pr create' 'pr comment' 'pr review' 'label create'; do
				printf 'Bash(%s %s:*)\n' "$gh" "$command"
			done
			# With a coder, the lead requests the user's review on her pull requests (#79 R27).
			[ -z "$coder_github" ] || printf 'Bash(%s pr edit:*)\n' "$gh"
			for type in feat fix docs refactor test chore ci; do
				printf 'Bash(git push -u origin %s/:*)\n' "$type"
				printf 'Bash(git push origin %s/:*)\n' "$type"
			done
			printf '%s\n' 'Bash(git push origin main)' 'Bash(git push origin --delete:*)'
			printf 'Bash(%s project item-edit:*)\n' "$gh"
			printf 'Bash(%s project item-add:*)\n' "$gh"
			if [ "$allow_releases" = yes ]; then
				printf 'Bash(%s release create:*)\n' "$gh"
				printf '%s\n' 'Bash(git push origin v:*)'
			fi
		fi
		if [ -n "$analyst_github" ]; then
			gh="GH_TOKEN=\$(gh auth token --user $analyst_github) gh"
			for command in 'issue create' 'issue edit' 'issue comment' 'issue close' \
				'label create' 'project item-edit' 'project item-list'; do
				printf 'Bash(%s %s:*)\n' "$gh" "$command"
			done
		fi
		# The coder: her issues, pull requests, work branches and board moves, but not main,
		# which the lead pushes when she merges (#79 R25, D25).
		if [ -n "$coder_github" ]; then
			gh="GH_TOKEN=\$(gh auth token --user $coder_github) gh"
			for command in 'issue create' 'issue edit' 'issue comment' \
				'pr create' 'pr comment' 'pr review' 'pr edit'; do
				printf 'Bash(%s %s:*)\n' "$gh" "$command"
			done
			for type in feat fix docs refactor test chore ci; do
				printf 'Bash(git push -u origin %s/:*)\n' "$type"
				printf 'Bash(git push origin %s/:*)\n' "$type"
			done
			# Only her work branches: a broad --delete rule would also match main.
			for type in feat fix docs refactor test chore ci; do
				printf 'Bash(git push origin --delete %s/:*)\n' "$type"
			done
			printf 'Bash(%s project item-edit:*)\n' "$gh"
			printf 'Bash(%s project item-add:*)\n' "$gh"
		fi
	} | awk '!seen[$0]++'
}

# add_permission_rules RULES SOURCE NEW: write to NEW the settings SOURCE with RULES (a file,
# one rule per line) added to "permissions.allow". Fail when the shape of SOURCE is not one
# that text processing can change safely (#67 R4, R6).
add_permission_rules() {
	if [ ! -s "$2" ] || [ "$(tr -d ' \t\r\n' <"$2")" = '{}' ]; then
		awk 'BEGIN { print "{"; print "  \"permissions\": {"; print "    \"allow\": [" }
			{ rules[++n] = $0 }
			END {
				for (k = 1; k <= n; k++) printf "      \"%s\"%s\n", rules[k], (k < n ? "," : "")
				print "    ]"; print "  }"; print "}"
			}' "$1" >"$3"
		return
	fi
	permissions=$(grep -o '"permissions"' "$2" | wc -l)
	if [ "$permissions" -eq 0 ]; then
		# No permissions key: a new one, as the first setting.
		grep -q '{' "$2" || return 1
		awk 'FNR == NR { rules[++n] = $0; next }
			!done && (i = index($0, "{")) {
				print substr($0, 1, i)
				print "  \"permissions\": {"
				print "    \"allow\": ["
				for (k = 1; k <= n; k++) printf "      \"%s\"%s\n", rules[k], (k < n ? "," : "")
				print "    ]"
				print "  },"
				rest = substr($0, i + 1)
				if (rest ~ /[^ \t]/) print rest
				done = 1
				next
			}
			{ print }' "$1" "$2" >"$3"
		return
	fi
	allow_shape "$2" || return 1
	case $(tr -d ' \t\r\n' <"$2") in
	*'"allow":[]'*) empty=1 ;;
	*) empty=0 ;;
	esac
	awk -v empty="$empty" 'FNR == NR { rules[++n] = $0; next }
		!done && match($0, /"allow"[ \t]*:[ \t]*\[/) {
			i = RSTART + RLENGTH - 1
			indent = $0
			sub(/[^ \t].*/, "", indent)
			print substr($0, 1, i)
			for (k = 1; k <= n; k++)
				printf "%s  \"%s\"%s\n", indent, rules[k], (k < n || !empty ? "," : "")
			rest = substr($0, i + 1)
			sub(/^[ \t]*/, "", rest)
			if (rest != "") print indent rest
			done = 1
			next
		}
		{ print }' "$1" "$2" >"$3"
}

# allow_shape FILE: whether FILE has a single "permissions" key and a single "allow" key,
# whose array opens at the end of its line or is empty.
allow_shape() {
	[ "$(grep -o '"permissions"' "$1" | wc -l)" -eq 1 ] &&
		[ "$(grep -o '"allow"' "$1" | wc -l)" -eq 1 ] &&
		grep -Eq '"allow"[[:space:]]*:[[:space:]]*\[[[:space:]]*(\].*)?$' "$1"
}

# remove_permission_rules RULES SOURCE NEW: write to NEW the settings SOURCE without one
# occurrence of each of RULES in "permissions.allow", and the comma that follows it, or
# precedes it for the last rule. Fail when the shape of SOURCE is not recognized, or a rule
# is not alone on its line in the array (#67 R7, R8, R14, R15).
remove_permission_rules() {
	allow_shape "$2" || return 1
	awk 'FNR == NR { wanted["\"" $0 "\""] = 1; left++; next }
		function flush() { if (held) print prev; held = 0 }
		inside && /^[ \t]*\]/ { inside = 0 }
		inside {
			key = $0
			sub(/^[ \t]+/, "", key)
			sub(/[ \t]+$/, "", key)
			comma = sub(/,$/, "", key)
			if ((key in wanted) && wanted[key]) {
				wanted[key] = 0
				left--
				# The last rule: the comma before it goes too.
				if (!comma && held) sub(/,[ \t]*$/, "", prev)
				next
			}
		}
		match($0, /"allow"[ \t]*:[ \t]*\[[ \t]*$/) { inside = 1 }
		{ flush(); prev = $0; held = 1 }
		END { flush(); exit (left > 0) }' "$1" "$2" >"$3"
}

# print_rules FILE: print the rules of FILE as JSON strings, for the user to copy.
print_rules() {
	while IFS= read -r rule; do
		printf '  "%s"\n' "$rule"
	done <"$1"
}

# sync_permissions [uninstall]: bring "permissions.allow" in settings.json in line with the
# rules the profile expects, and record in $permissions_record the rules kirakit inserted.
# A rule already present that kirakit did not insert is the user's: neither recorded nor
# removed. With "uninstall", every recorded rule is removed (#67 R1 to R9, R12 to R15).
sync_permissions() {
	settings=$CLAUDE_DIR/settings.json
	work_dir
	expected=$work/permissions-expected
	recorded=$work/permissions-recorded
	add=$work/permissions-add
	remove=$work/permissions-remove
	if [ "${1-}" = uninstall ]; then : >"$expected"; else permission_rules >"$expected"; fi
	if [ -f "$permissions_record" ]; then cp "$permissions_record" "$recorded"; else : >"$recorded"; fi
	: >"$add"
	: >"$remove"
	# R5, R13: an expected rule missing from the file is added, recorded or not.
	while IFS= read -r rule; do
		if [ ! -f "$settings" ] || ! grep -qF "\"$rule\"" "$settings"; then
			printf '%s\n' "$rule" >>"$add"
		fi
	done <"$expected"
	# R7, R8: a recorded rule no longer expected is removed, when it is still there.
	while IFS= read -r rule; do
		[ -n "$rule" ] || continue
		if ! grep -qxF -- "$rule" "$expected" && [ -f "$settings" ] && grep -qF "\"$rule\"" "$settings"; then
			printf '%s\n' "$rule" >>"$remove"
		fi
	done <"$recorded"

	changed=0
	if [ ! -s "$add" ] && [ ! -s "$remove" ]; then
		[ ! -s "$expected" ] || log "up to date: $settings (permissions)"
	else
		new=$work/settings.json
		if [ -f "$settings" ]; then cp "$settings" "$new.0"; else : >"$new.0"; fi
		if [ -s "$remove" ]; then
			if remove_permission_rules "$remove" "$new.0" "$new.1"; then
				mv "$new.1" "$new.0"
			else
				log "warning: cannot remove the permission rules from $settings safely; left unchanged. Remove them by hand from \"permissions\": {\"allow\": [...]}:"
				print_rules "$remove"
				if [ -s "$add" ]; then
					log "warning: nor add the permission rules; add them by hand to \"permissions\": {\"allow\": [...]}:"
					print_rules "$add"
				fi
				# R15: the record is kept, so that a later run retries; uninstall drops it.
				[ "${1-}" != uninstall ] || remove_permissions_record
				return 0
			fi
		fi
		if [ -s "$add" ]; then
			if add_permission_rules "$add" "$new.0" "$new.1"; then
				mv "$new.1" "$new.0"
			else
				log "warning: cannot add the permission rules to $settings safely; left unchanged. Add them by hand to \"permissions\": {\"allow\": [...]}:"
				print_rules "$add"
				return 0
			fi
		fi
		backup_settings
		while IFS= read -r rule; do
			log "remove permission: $rule from $settings"
		done <"$remove"
		while IFS= read -r rule; do
			log "set permission: $rule in $settings"
		done <"$add"
		if [ "$dry_run" -eq 0 ]; then
			mkdir -p "$CLAUDE_DIR"
			# Write in place to keep the file's permissions and any symlink.
			cat "$new.0" >"$settings"
		fi
		changed=1
	fi

	if [ "${1-}" = uninstall ]; then
		remove_permissions_record
		return 0
	fi
	# The record: the expected rules kirakit inserted, now or earlier (R12).
	while IFS= read -r rule; do
		if grep -qxF -- "$rule" "$recorded" || { [ "$changed" -eq 1 ] && grep -qxF -- "$rule" "$add"; }; then
			printf '%s\n' "$rule"
		fi
	done <"$expected" >"$work/permissions-record"
	if [ ! -s "$work/permissions-record" ]; then
		remove_permissions_record
	elif [ ! -f "$permissions_record" ] || ! cmp -s "$work/permissions-record" "$permissions_record"; then
		log "save permission record: $permissions_record"
		if [ "$dry_run" -eq 0 ]; then
			mkdir -p "$CLAUDE_DIR"
			cat "$work/permissions-record" >"$permissions_record"
		fi
	fi
}

remove_permissions_record() {
	if [ -f "$permissions_record" ]; then
		log "remove permission record: $permissions_record"
		run rm -f -- "$permissions_record"
	fi
}

install_claude() {
	if [ -f "$src/claude/CLAUDE.md" ]; then
		install_built CLAUDE.md "$CLAUDE_DIR/CLAUDE.md"
	fi
	for file in "$src"/claude/agents/*.md; do
		[ -f "$file" ] || continue
		agent=$(basename "$file")
		install_built "agents/$agent" "$CLAUDE_DIR/agents/$agent"
	done
	for file in "$src"/team/*.md; do
		[ -f "$file" ] || continue
		agent=$(basename "$file")
		install_built "agents/$agent" "$CLAUDE_DIR/agents/$agent"
	done
	# Claude Code loads every file of rules/ on its own.
	for file in "$src"/claude/rules/*.md; do
		[ -f "$file" ] || continue
		rules=$(basename "$file")
		install_built "rules/$rules" "$CLAUDE_DIR/rules/$rules"
	done
	# Skills are directories holding a SKILL.md, installed as a whole.
	for dir in "$src"/claude/skills/*/; do
		[ -f "$dir/SKILL.md" ] || continue
		skill=$(basename "$dir")
		install_built "skills/$skill" "$CLAUDE_DIR/skills/$skill"
	done
	# Each team member's command, a skill built from team/NAME.md.
	for file in "$src"/team/*.md; do
		[ -f "$file" ] || continue
		member=$(basename "$file" .md)
		install_built "skills/$member" "$CLAUDE_DIR/skills/$member"
	done
	set_output_style
	set_attribution
	sync_permissions
}

# Copy github/ into the target repository's .github directory. Files are always copied:
# they belong to that repository and are committed there.
install_github() {
	if [ -z "$github_target" ]; then
		github_target=$(git rev-parse --show-toplevel 2>/dev/null) ||
			die "--only github needs a Git repository: run it from one or pass --target DIR"
	fi
	[ -d "$github_target" ] || die "not a directory: $github_target"
	github_target=$(CDPATH='' cd -- "$github_target" && pwd)
	log "github target: $github_target/.github"
	mode=copy
	find "$src/github" -type f ! -name .gitkeep | sort | while IFS= read -r file; do
		rel=${file#"$src/github/"}
		install_file "$file" "$github_target/.github/$rel" "$github_target" \
			"github/$(basename "$github_target")/"
	done
}

# Merge this run's targets into the manifest read by --uninstall, and the backups of files
# that were there before kirakit into the list of originals; drop the files this run removed.
write_manifest() {
	[ -n "$installed$removed" ] || return 0
	if [ "$dry_run" -eq 1 ]; then
		printf '[dry-run] record installed files in %s\n' "$manifest"
		return
	fi
	# --only launchers may install nothing in the configuration directory itself.
	mkdir -p -- "$CLAUDE_DIR"
	{
		if [ -f "$manifest" ]; then
			cat "$manifest"
		fi
		printf '%s' "$installed"
	} | sort -u | without_removed >"$manifest.tmp"
	mv -f "$manifest.tmp" "$manifest"
	if [ -n "$originals_new" ]; then
		printf '%s' "$originals_new" >>"$originals"
	fi
	if [ -n "$removed" ] && [ -f "$originals" ]; then
		without_removed <"$originals" >"$originals.tmp"
		mv -f "$originals.tmp" "$originals"
	fi
}

# Filter out the lines whose first field is a path this run removed.
without_removed() {
	KIRAKIT_REMOVED=$removed awk -F "$tab" '
		BEGIN { n = split(ENVIRON["KIRAKIT_REMOVED"], paths, "\n"); for (i = 1; i <= n; i++) gone[paths[i]] = 1 }
		!($1 in gone)'
}

# remove_installed PATH: remove a file kirakit installed (a symlink is deleted, a copy is
# moved to the backups) and restore what was there before kirakit.
remove_installed() {
	if [ -L "$1" ]; then
		log "remove link: $1"
		run rm -f -- "$1"
	elif [ -e "$1" ]; then
		backup "$1"
	fi
	original=
	if [ -f "$originals" ]; then
		original=$(awk -F "$tab" -v path="$1" '$1 == path { print $2; exit }' "$originals")
	fi
	if [ -n "$original" ] && { [ -e "$original" ] || [ -L "$original" ]; }; then
		log "restore: $original -> $1"
		run mv -- "$original" "$1"
	fi
}

# Remove what the manifest lists.
uninstall_all() {
	[ -f "$manifest" ] || die "nothing to uninstall: $manifest not found"
	load_profile
	resolve_launcher_dirs
	while IFS= read -r path; do
		case $path in
		'') continue ;;
		*/../* | */..) log "skip: $path" && continue ;;
		"$CLAUDE_DIR"/* | "$konsole_dir"/kirakit-*.colorscheme) ;;
		"$bin_dir"/assistant | "$bin_dir"/analyst | "$bin_dir"/team | "$bin_dir"/kirakit-session | "$bin_dir"/kirakit-watch) ;;
		*)
			if in_default_launcher_location "$path"; then
				log "skip (default launcher location): $path"
			else
				log "skip (outside $CLAUDE_DIR): $path"
			fi
			continue
			;;
		esac
		remove_installed "$path"
	done <"$manifest"
	log "remove manifest: $manifest"
	run rm -f -- "$manifest" "$originals"
	# R8: only the rules kirakit added, as recorded.
	sync_permissions uninstall
	log "kept: $profile, $CLAUDE_DIR/.kirakit-backups and the outputStyle and attribution settings"
}

while [ $# -gt 0 ]; do
	case $1 in
	--dry-run) dry_run=1 ;;
	--name | --gender | --language | --co-author | --assistant | --assistant-signing-key | \
		--assistant-github | --analyst-github | --default-style | --persona | --only | --target | \
		--assistant-style | --bin-dir | --color-scheme-dir | --coder | --coder-signing-key | --coder-github)
		[ $# -ge 2 ] || die "missing value for $1"
		case $1 in
		--name) opt_name=$2 ;;
		--gender)
			case $2 in
			male | female | nonbinary | unspecified) opt_gender=$2 ;;
			*) die "unknown gender: $2 (expected male, female, nonbinary or unspecified)" ;;
			esac
			;;
		--language) opt_language=$2 ;;
		--co-author | --assistant)
			if [ -z "$2" ] || ! valid_co_author "$2"; then
				die "invalid ${1#--}: $2 (expected \"NAME <EMAIL>\")"
			fi
			opt_assistant=$2
			# --co-author predates the assistant identity: it also asks for the trailer.
			[ "$1" = --assistant ] || opt_co_author_trailer=yes
			;;
		--assistant-signing-key)
			case $2 in *"$nl"*) die "invalid signing key path: $2" ;; esac
			opt_assistant_signing_key=$2
			;;
		--assistant-github)
			valid_github "$2" || die "invalid GitHub login: $2"
			opt_assistant_github=$2
			;;
		--analyst-github)
			valid_github "$2" || die "invalid GitHub login: $2"
			opt_analyst_github=$2
			;;
		--coder)
			if [ -z "$2" ] || ! valid_co_author "$2"; then
				die "invalid coder: $2 (expected \"NAME <EMAIL>\")"
			fi
			opt_coder=$2
			;;
		--coder-signing-key)
			case $2 in *"$nl"*) die "invalid signing key path: $2" ;; esac
			opt_coder_signing_key=$2
			;;
		--coder-github)
			valid_github "$2" || die "invalid GitHub login: $2"
			opt_coder_github=$2
			;;
		--default-style | --persona | --assistant-style)
			case $2 in
			'' | -* | *[!A-Za-z0-9_-]*) die "invalid persona name: $2" ;;
			esac
			case $1 in
			--persona) personas="$personas $2" ;;
			--assistant-style) opt_assistant_style=$2 ;;
			*) opt_style=$2 ;;
			esac
			;;
		--bin-dir)
			case $2 in '' | *"$nl"*) die "invalid bin directory: $2" ;; esac
			opt_bin_dir=$2
			;;
		--color-scheme-dir)
			case $2 in '' | *"$nl"*) die "invalid color scheme directory: $2" ;; esac
			opt_color_scheme_dir=$2
			;;
		--only)
			case $2 in
			styles | claude | launchers | github) only=$2 ;;
			*) die "unknown component: $2 (expected styles, claude, launchers or github)" ;;
			esac
			;;
		--target) github_target=$2 ;;
		esac
		shift
		;;
	--no-co-author) opt_co_author_trailer=no ;;
	--allow-releases) opt_allow_releases=yes ;;
	--no-allow-releases) opt_allow_releases=no ;;
	--complete-approved-prs) opt_complete_approved_prs=yes ;;
	--no-complete-approved-prs) opt_complete_approved_prs=no ;;
	--start-verified-specs) opt_start_verified_specs=yes ;;
	--no-start-verified-specs) opt_start_verified_specs=no ;;
	--analyst) opt_analyst=yes ;;
	--no-analyst) opt_analyst=no ;;
	--reconfigure) reconfigure=1 ;;
	--link) mode='link' ;;
	--copy) mode=copy ;;
	--uninstall) uninstall=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown option: $1 (see --help)" ;;
	esac
	shift
done

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[ "$dry_run" -eq 0 ] || log "dry run: nothing will be changed"

if [ "$uninstall" -eq 1 ]; then
	uninstall_all
	log "done"
	exit 0
fi

# Use the clone this script lives in, if any; otherwise fetch the repository.
src=
case $0 in
*get-kira.sh)
	dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
	if [ -f "$dir/personas/_core.md" ]; then
		src=$dir
	fi
	;;
esac

if [ -z "$src" ]; then
	[ "$mode" != link ] || die "--link needs a local clone: run get-kira.sh from the repository"
	command -v git >/dev/null 2>&1 || die "git is required"
	work_dir
	ref=$(resolve_ref)
	log "fetching $KIRAKIT_REPO ($ref)"
	# An empty repository, a shallow fetch and a checkout of FETCH_HEAD: unlike a shallow
	# clone, they print no detached HEAD advice and no "is not a commit" warning for an
	# annotated tag, while git's errors still reach stderr.
	{ git init --quiet -- "$work/repo" &&
		git -C "$work/repo" fetch --quiet --depth 1 -- "$KIRAKIT_REPO" "$ref" &&
		git -C "$work/repo" -c advice.detachedHead=false checkout --quiet FETCH_HEAD; } ||
		die "could not fetch $KIRAKIT_REPO"
	src=$work/repo
	mode=copy
fi
[ -n "$mode" ] || mode='link'

for persona in $personas ${opt_style-} ${opt_assistant_style-}; do
	[ -f "$src/personas/$persona.md" ] || die "unknown persona: $persona"
done

log "source: $src ($mode mode)"

if [ "$only" = github ]; then
	install_github
	log "done"
	exit 0
fi

log "target: $CLAUDE_DIR"
setup_profile
[ -f "$src/personas/$default_style.md" ] || die "unknown default style: $default_style"
log "profile: ${user_name:-(no name)}, $user_gender, language $user_language, assistant ${assistant:-none}, co-author trailers $co_author_trailer, analyst $analyst${analyst_github:+ ($analyst_github)}, coder ${coder:-none}, style $default_style"
check_signing_key 'the assistant' "$assistant_signing_key"
check_signing_key 'the coder' "$coder_signing_key"
build

if [ -z "$only" ] || [ "$only" = styles ]; then
	install_styles
fi
if [ -z "$only" ] || [ "$only" = claude ]; then
	install_claude
fi
if [ -z "$only" ] || [ "$only" = launchers ]; then
	install_launchers
fi
write_manifest

log "done"
