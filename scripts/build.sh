#!/bin/sh
# Build the personalized Claude Code files into DIR (default: dist/):
#   DIR/output-styles/<persona>.md   from personas/_core.md and one overlay per persona
#   DIR/skills/<skill>/              from claude/skills/<skill>/
#   DIR/agents/<agent>.md            from claude/agents/<agent>.md
#   DIR/rules/<rules>.md             from claude/rules/<rules>.md
#   DIR/CLAUDE.md                    from claude/CLAUDE.md
#   DIR/output-styles/<member>.md, DIR/agents/<member>.md and DIR/skills/<member>/SKILL.md
#                                    from team/<member>.md
#   DIR/konsole/<scheme>.colorscheme from launchers/konsole/<scheme>.colorscheme
#   DIR/bin/<launcher>               from launchers/<launcher>, executable
#
# An overlay is a Markdown file whose front matter becomes the style's front matter and
# whose body replaces the {{overlay}} marker of the core text. Files starting with "_" in
# personas/ are not personas.
#
# Markdown files can use these placeholders, filled from the options:
#   {{user}}                  name and description, e.g. "Alex, a female staff software developer"
#   {{they}} {{them}} {{their}}  pronouns (avoid verbs that agree with {{they}})
#   {{language}}              answer language, e.g. "French" or "the language of the conversation"
#   {{co_author}}             the co-author, "NAME <EMAIL>", or nothing
#   {{assistant_name}} {{assistant_email}}  the assistant's git identity, or nothing
#   {{assistant_signing_key}} path to the assistant's public SSH signing key, or nothing
#   {{assistant_github}}      the assistant's GitHub login, or nothing
#   {{analyst}}               "yes" when the team has an analyst, or nothing
#   {{analyst_github}}        the analyst's GitHub login, or nothing
#   {{coder}}                 the coder's git identity, "NAME <EMAIL>", or nothing
#   {{coder_name}} {{coder_email}}  the coder's name and email, or nothing
#   {{coder_signing_key}}     path to the coder's public SSH signing key, or nothing
#   {{coder_github}}          the coder's GitHub login, or nothing
#   {{committer}}             who commits with the assistant-commit skill: "the coder" when the
#                             team has a coder, "the assistant" otherwise
#   {{committer_name}} {{committer_email}} {{committer_signing_key}}  that member's git identity
#                             and signing key: the coder's with a coder, the assistant's otherwise
#   {{team_github}}           "yes" when a member of the team (the assistant, the analyst or the
#                             coder) has a GitHub account, or nothing. Derived, not an option.
#   {{any_committer_key}}     "yes" when a member can commit with the assistant-commit skill:
#                             the committer has a signing key or, with a coder, the assistant
#                             has one; or nothing. Derived, not an option.
#   {{assistant_style}}       the name of the assistant's output style, e.g. "Kira (cozy)"
#   {{analyst_style}}         the name of the analyst's output style, "Iris"
#   {{complete_approved_prs}} "yes" when the lead may complete the coder's pull requests she
#                             approved without the user's review, or nothing
#   {{start_verified_specs}}  "yes" when the lead verifies the analyst's specifications and moves
#                             the verified ones to Ready without the user, or nothing; set only
#                             when the team has both an analyst and a coder
# In the launchers, {{assistant_name}} is "Kira" when the assistant has no git identity.
# A line holding only a placeholder that expands to nothing is removed.
#
# Lines between {{#KEY}} and {{/KEY}} are kept only when KEY is not empty, and lines between
# {{^KEY}} and {{/KEY}} only when it is; KEY is any placeholder above. The markers stand on
# lines of their own, are removed, and blocks can nest. A file (a skill: its SKILL.md) that
# renders to nothing is not built, so a template wholly inside a block is optional.
#
# Usage: build.sh [-o DIR] [--name NAME] [--gender GENDER] [--language LANGUAGE]
#                 [--co-author "NAME <EMAIL>"] [--assistant "NAME <EMAIL>"]
#                 [--assistant-signing-key PATH] [--assistant-github LOGIN]
#                 [--analyst] [--analyst-github LOGIN] [--assistant-style PERSONA]
#                 [--coder "NAME <EMAIL>"] [--coder-signing-key PATH] [--coder-github LOGIN]
#                 [--complete-approved-prs] [--start-verified-specs] [PERSONA...]
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
personas_dir=$root/personas
claude_dir=$root/claude
skills_dir=$claude_dir/skills
out_dir=$root/dist
name=
gender=unspecified
language=auto
co_author=
assistant=
assistant_signing_key=
assistant_github=
analyst=
analyst_github=
coder=
coder_signing_key=
coder_github=
complete_approved_prs=
start_verified_specs=
assistant_style=kira-cozy
nl='
'

die() {
	printf 'build: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<EOF
Usage: build.sh [-o DIR] [--name NAME] [--gender GENDER] [--language LANGUAGE]
                [--co-author "NAME <EMAIL>"] [--assistant "NAME <EMAIL>"]
                [--assistant-signing-key PATH] [--assistant-github LOGIN]
                [--analyst] [--analyst-github LOGIN] [--assistant-style PERSONA]
                [--coder "NAME <EMAIL>"] [--coder-signing-key PATH] [--coder-github LOGIN]
                [--complete-approved-prs] [--start-verified-specs] [PERSONA...]

Build output styles, skills, agents, rules, CLAUDE.md and the launchers into DIR
(default: dist).
With no PERSONA, build every overlay in personas/. Skills are always all built.

  --name NAME                How Kira calls the user (default: none)
  --gender GENDER            male, female, nonbinary or unspecified (default: unspecified)
  --language LANGUAGE        Answer language, or auto to follow the conversation (default: auto)
  --co-author "NAME <EMAIL>" Co-Authored-By trailer for commits (default: none)
  --assistant "NAME <EMAIL>" The assistant's git identity (default: none)
  --assistant-signing-key PATH
                             The assistant's public SSH signing key (default: none; with a
                             coder, the coder then commits its work)
  --assistant-github LOGIN   The assistant's GitHub account (default: none)
  --analyst                  The team has an analyst, Iris (default: no)
  --analyst-github LOGIN     The analyst's GitHub account, with --analyst (default: none)
  --assistant-style PERSONA  The assistant launcher's output style (default: kira-cozy)
  --coder "NAME <EMAIL>"     The coder's git identity (default: none)
  --coder-signing-key PATH   The coder's public SSH signing key, with --coder (default: none;
                             the assistant then commits her work)
  --coder-github LOGIN       The coder's GitHub account, with --coder (default: none)
  --complete-approved-prs    The lead may complete the coder's pull requests she approved
                             without the user's review (default: no)
  --start-verified-specs     With an analyst and a coder, the lead verifies the analyst's
                             specifications and moves the verified ones to Ready without the
                             user (default: no)
EOF
}

while [ $# -gt 0 ]; do
	case $1 in
	-o | --out | --name | --gender | --language | --co-author | --assistant | \
		--assistant-signing-key | --assistant-github | --analyst-github | --assistant-style | \
		--coder | --coder-signing-key | --coder-github)
		[ $# -ge 2 ] || die "missing value for $1"
		case $1 in
		--name) name=$2 ;;
		--gender) gender=$2 ;;
		--language) language=$2 ;;
		--co-author) co_author=$2 ;;
		--assistant) assistant=$2 ;;
		--assistant-signing-key) assistant_signing_key=$2 ;;
		--assistant-github) assistant_github=$2 ;;
		--analyst-github) analyst_github=$2 ;;
		--assistant-style) assistant_style=$2 ;;
		--coder) coder=$2 ;;
		--coder-signing-key) coder_signing_key=$2 ;;
		--coder-github) coder_github=$2 ;;
		*) out_dir=$2 ;;
		esac
		shift 2
		;;
	--analyst)
		analyst=yes
		shift
		;;
	--complete-approved-prs)
		complete_approved_prs=yes
		shift
		;;
	--start-verified-specs)
		start_verified_specs=yes
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	--)
		shift
		break
		;;
	-*) die "unknown option: $1" ;;
	*) break ;;
	esac
done

for value in "$name" "$language" "$co_author" "$assistant" "$assistant_signing_key" "$coder" \
	"$coder_signing_key"; do
	case $value in
	*"$nl"* | *'{{'* | *'}}'*) die "invalid value: $value" ;;
	esac
done

case $gender in
male) they=he them=him their=his adjective='male ' ;;
female) they=she them=her their=her adjective='female ' ;;
nonbinary) they=they them=them their=their adjective='non-binary ' ;;
unspecified) they=they them=them their=their adjective= ;;
*) die "unknown gender: $gender (expected male, female, nonbinary or unspecified)" ;;
esac

user="a ${adjective}staff software developer"
if [ -n "$name" ]; then
	user="$name, $user"
fi

case $language in
'' | auto) language='the language of the conversation' ;;
esac

case $co_author in
'' | ?*' <'?*@?*'>') ;;
*) die "invalid co-author: $co_author (expected \"NAME <EMAIL>\")" ;;
esac

case $assistant in
'') assistant_name='' assistant_email='' ;;
?*' <'?*@?*'>')
	assistant_name=${assistant% <*}
	assistant_email=${assistant##*<}
	assistant_email=${assistant_email%>}
	;;
*) die "invalid assistant: $assistant (expected \"NAME <EMAIL>\")" ;;
esac

case $coder in
'') coder_name='' coder_email='' ;;
?*' <'?*@?*'>')
	coder_name=${coder% <*}
	coder_email=${coder##*<}
	coder_email=${coder_email%>}
	;;
*) die "invalid coder: $coder (expected \"NAME <EMAIL>\")" ;;
esac

for login in "$assistant_github" "$analyst_github" "$coder_github"; do
	case $login in
	*[!A-Za-z0-9-]*) die "invalid GitHub login: $login" ;;
	esac
done
# The analyst's account means nothing without an analyst.
[ -n "$analyst" ] || analyst_github=
# Nor do the coder's key and account without a coder.
[ -n "$coder" ] || coder_signing_key='' coder_github=''
# Verified specifications start without the user only with both an analyst, who writes them,
# and a coder, whose team has the lead's kira agent that verifies them.
if [ -z "$analyst" ] || [ -z "$coder" ]; then
	start_verified_specs=
fi
# The team's accounts: the members' sessions mark what they write as these accounts.
team_github=
if [ -n "$assistant_github$analyst_github$coder_github" ]; then
	team_github=yes
fi
# With a coder, the committer is the coder, who writes and commits the code by default; the
# assistant commits with its own keys only the code it writes at the user's explicit request,
# or the coder's work when she has no key.
if [ -n "$coder" ]; then
	committer='the coder' committer_name=$coder_name committer_email=$coder_email
	committer_signing_key=$coder_signing_key
else
	committer='the assistant' committer_name=$assistant_name committer_email=$assistant_email
	committer_signing_key=$assistant_signing_key
fi
# With a coder, the assistant commits the code she wrote at the user's explicit request with
# her own key, whatever the coder's key.
any_committer_key=
if [ -n "$committer_signing_key" ] || { [ -n "$coder" ] && [ -n "$assistant_signing_key" ]; }; then
	any_committer_key=yes
fi

# The launchers start a member with the name of their output style.
case $assistant_style in
'' | -* | *[!A-Za-z0-9_-]*) die "invalid persona name: $assistant_style" ;;
esac
[ -f "$personas_dir/$assistant_style.md" ] || die "unknown persona: $assistant_style"
assistant_style_name=$(sed -n 's/^name: //p' "$personas_dir/$assistant_style.md" | head -n 1)
analyst_style_name=$(sed -n 's/^name: //p' "$root/team/iris.md" | head -n 1)
for value in "$assistant_style_name" "$analyst_style_name" "$assistant_name"; do
	case $value in
	*\'* | *'"'* | *\\*) die "cannot use this name in a launcher: $value" ;;
	esac
done

export KIRA_USER="$user" KIRA_THEY="$they" KIRA_THEM="$them" KIRA_THEIR="$their" \
	KIRA_LANGUAGE="$language" KIRA_CO_AUTHOR="$co_author" KIRA_ASSISTANT_NAME="$assistant_name" \
	KIRA_ASSISTANT_EMAIL="$assistant_email" KIRA_ASSISTANT_SIGNING_KEY="$assistant_signing_key" \
	KIRA_ASSISTANT_GITHUB="$assistant_github" KIRA_ANALYST="$analyst" KIRA_ANALYST_GITHUB="$analyst_github" \
	KIRA_ASSISTANT_STYLE="$assistant_style_name" KIRA_ANALYST_STYLE="$analyst_style_name" \
	KIRA_CODER="$coder" KIRA_CODER_NAME="$coder_name" KIRA_CODER_EMAIL="$coder_email" \
	KIRA_CODER_SIGNING_KEY="$coder_signing_key" KIRA_CODER_GITHUB="$coder_github" \
	KIRA_COMMITTER="$committer" KIRA_COMMITTER_NAME="$committer_name" KIRA_COMMITTER_EMAIL="$committer_email" \
	KIRA_COMMITTER_SIGNING_KEY="$committer_signing_key" KIRA_COMPLETE_APPROVED_PRS="$complete_approved_prs" \
	KIRA_ANY_COMMITTER_KEY="$any_committer_key" KIRA_TEAM_GITHUB="$team_github" \
	KIRA_START_VERIFIED_SPECS="$start_verified_specs"

# render FILE [ORIGIN]: print FILE with its placeholders filled and its blocks resolved;
# errors name ORIGIN (default: FILE).
render() {
	awk -v file="${2:-$1}" '
		# Literal replacement: values may contain characters special to gsub.
		function replace(s, key, value,   i, out) {
			out = ""
			while ((i = index(s, key)) > 0) {
				out = out substr(s, 1, i - 1) value
				s = substr(s, i + length(key))
			}
			return out s
		}
		function fail(message, where) {
			printf "build: %s:%s: %s\n", file, where, message > "/dev/stderr"
			failed = 1
			exit 1
		}
		BEGIN {
			n = split("user they them their language co_author assistant_name assistant_email assistant_signing_key assistant_github analyst analyst_github assistant_style analyst_style coder coder_name coder_email coder_signing_key coder_github committer committer_name committer_email committer_signing_key complete_approved_prs start_verified_specs any_committer_key team_github", keys, " ")
			for (k = 1; k <= n; k++) known[keys[k]] = 1
			depth = 0
			hidden = 0
		}
		# Block markers: {{#KEY}}, {{^KEY}} and {{/KEY}} on lines of their own.
		/^\{\{[#^\/][a-z_]+\}\}$/ {
			kind = substr($0, 3, 1)
			key = substr($0, 4, length($0) - 5)
			if (!(key in known)) fail("unknown block " key, NR)
			if (kind == "/") {
				if (depth == 0 || open[depth] != key) fail("unexpected {{/" key "}}", NR)
				if (!shown[depth]) hidden--
				depth--
			} else {
				set = ENVIRON["KIRA_" toupper(key)] != ""
				depth++
				open[depth] = key
				shown[depth] = (kind == "#") ? set : !set
				if (!shown[depth]) hidden++
			}
			next
		}
		hidden { next }
		{
			for (k = 1; k <= n; k++) {
				key = "{{" keys[k] "}}"
				value = ENVIRON["KIRA_" toupper(keys[k])]
				if ($0 == key && value == "") next
				$0 = replace($0, key, value)
			}
			print
		}
		END {
			if (!failed && depth > 0) fail("missing {{/" open[depth] "}}", "end")
		}' "$1"
}

# check FILE SOURCE: fail on any placeholder left in FILE.
check() {
	unknown=$(sed -n 's/.*\({{[^}]*}}\).*/\1/p' "$1" | head -n 1)
	[ -z "$unknown" ] || die "$2: unknown placeholder $unknown"
}

# blank FILE: whether FILE rendered to nothing, such as a template wholly inside a block that
# is dropped for this profile. Such a file is not built, and an earlier build of it is removed.
blank() {
	! grep -q '[^[:space:]]' "$1"
}

core=$personas_dir/_core.md
[ -f "$core" ] || die "missing $core"
grep -qF '{{overlay}}' "$core" || die "$core: missing {{overlay}} marker"

if [ $# -eq 0 ]; then
	for file in "$personas_dir"/*.md; do
		persona=$(basename "$file" .md)
		case $persona in _*) continue ;; esac
		set -- "$@" "$persona"
	done
fi

build_style() {
	overlay=$personas_dir/$1.md
	[ -f "$overlay" ] || die "unknown persona: $1"
	awk 'NR == 1 && $0 != "---" { exit 1 } NR > 1 && $0 == "---" { found = 1; exit } END { exit !found }' "$overlay" ||
		die "$overlay: missing front matter"

	dir=$out_dir/output-styles
	body=$dir/.$1.body.tmp
	merged=$dir/.$1.merged.tmp
	# Overlay body, without the blank lines that follow the front matter.
	awk 'body && (started || $0 != "") { started = 1; print } NR > 1 && $0 == "---" { body = 1 }' "$overlay" >"$body"
	{
		# Front matter, delimiters included.
		awk '{ print } NR > 1 && $0 == "---" { exit }' "$overlay"
		printf '\n'
		awk -v body="$body" '
			BEGIN { while ((getline line < body) > 0) text = (n++ ? text "\n" : "") line }
			i = index($0, "{{overlay}}") { $0 = substr($0, 1, i - 1) text substr($0, i + 11) }
			{ print }' "$core"
	} >"$merged"
	render "$merged" "$overlay" >"$dir/.$1.md.tmp" || {
		rm -f "$body" "$merged" "$dir/.$1.md.tmp"
		exit 1
	}
	rm -f "$body" "$merged"
	if blank "$dir/.$1.md.tmp"; then
		rm -f "$dir/.$1.md.tmp" "$dir/$1.md"
		return
	fi
	check "$dir/.$1.md.tmp" "$overlay" || {
		rm -f "$dir/.$1.md.tmp"
		exit 1
	}
	mv -f "$dir/.$1.md.tmp" "$dir/$1.md"
	printf '%s\n' "$dir/$1.md"
}

# build_file SOURCE DEST: render one file.
build_file() {
	mkdir -p "$(dirname "$2")"
	render "$1" >"$2.tmp" || {
		rm -f "$2.tmp"
		exit 1
	}
	if blank "$2.tmp"; then
		rm -f "$2.tmp" "$2"
		return
	fi
	check "$2.tmp" "$1" || {
		rm -f "$2.tmp"
		exit 1
	}
	mv -f "$2.tmp" "$2"
	printf '%s\n' "$2"
}

# front_matter FILE KEY: the value of KEY in the front matter of FILE.
front_matter() {
	awk -v key="$2: " 'NR > 1 && $0 == "---" { exit } index($0, key) == 1 { print substr($0, length(key) + 1); exit }' "$1"
}

# build_member FILE: render a team member's persona (team/NAME.md), written once, into both an
# output style and an agent with the same body, and a command (skills/NAME/SKILL.md) that lets
# the user talk to the member directly: a skill forked into her agent, which only the user can
# run. Its front matter holds the style's name and description, "delegate", the agent's
# description: when to hand work to this member, and "model", the agent's model (haiku, sonnet
# or opus), which every member declares.
build_member() {
	member=$(basename "$1" .md)
	# The member's command is named after her: it must not replace a skill of claude/skills/.
	[ ! -d "$skills_dir/$member" ] ||
		die "$1: the command of team member $member has the same name as the skill claude/skills/$member"
	rendered=$out_dir/.$member.member.tmp
	body=$out_dir/.$member.body.tmp
	style=$out_dir/output-styles/$member.md
	agent=$out_dir/agents/$member.md
	command=$out_dir/skills/$member
	render "$1" >"$rendered" || {
		rm -f "$rendered"
		exit 1
	}
	if blank "$rendered"; then
		rm -f "$rendered" "$style" "$agent"
		rm -rf "$command"
		return
	fi
	check "$rendered" "$1" || {
		rm -f "$rendered"
		exit 1
	}
	title=$(front_matter "$rendered" name)
	description=$(front_matter "$rendered" description)
	delegate=$(front_matter "$rendered" delegate)
	model=$(front_matter "$rendered" model)
	if [ "$(head -n 1 "$rendered")" != --- ] || [ -z "$title" ] || [ -z "$description" ] || [ -z "$delegate" ]; then
		rm -f "$rendered"
		die "$1: missing front matter with name, description and delegate"
	fi
	if [ -z "$model" ]; then
		rm -f "$rendered"
		die "$1: missing model in the front matter"
	fi
	# Body, without the blank lines that follow the front matter.
	awk 'body && (started || $0 != "") { started = 1; print } NR > 1 && $0 == "---" { body = 1 }' "$rendered" >"$body"
	mkdir -p "$out_dir/agents"
	{
		printf '%s
' --- "name: $title" "description: $description" 'keep-coding-instructions: true' --- ''
		cat "$body"
	} >"$style.tmp"
	{
		printf '%s
' --- "name: $member" "description: $delegate" "model: $model" --- ''
		cat "$body"
	} >"$agent.tmp"
	rm -f "$rendered" "$body"
	# $ARGUMENTS is filled by Claude Code with what the user typed after the command.
	rm -rf "$command.tmp"
	mkdir -p "$command.tmp"
	# shellcheck disable=SC2016
	{
		printf '%s\n' --- "name: $member" \
			"description: Talk to $title directly: she handles your request in her own persona and answers you." \
			"model: $model" 'context: fork' "agent: $member" 'disable-model-invocation: true' --- ''
		printf '%s\n' \
			"The user addresses you directly with the \`/$member\` command, from the lead's conversation." \
			'Their request:' \
			'' \
			'$ARGUMENTS' \
			'' \
			'Handle it as one exchange, in your own persona and under your own rules, and end with your' \
			'answer to the user, written for the user, your questions included.' \
			'' \
			'When the request above is empty, answer in one line asking what the user wants from you.'
	} >"$command.tmp/SKILL.md"
	mv -f "$style.tmp" "$style"
	mv -f "$agent.tmp" "$agent"
	rm -rf "$command"
	mv "$command.tmp" "$command"
	printf '%s\n%s\n%s\n' "$style" "$agent" "$command"
}

# Skills are copied whole, with their Markdown files rendered.
build_skill() {
	skill=$(basename "$1")
	dest=$out_dir/skills/$skill
	rm -rf "$dest.tmp"
	cp -R "$1" "$dest.tmp"
	find "$dest.tmp" -type f -name '*.md' | while IFS= read -r file; do
		origin=$1/${file#"$dest.tmp"/}
		# Explicit exit: errexit does not apply on the left of the || below.
		render "$file" "$origin" >"$file.rendered" || exit 1
		mv -f "$file.rendered" "$file"
		check "$file" "$origin"
	done || {
		rm -rf "$dest.tmp"
		exit 1
	}
	rm -rf "$dest"
	if blank "$dest.tmp/SKILL.md"; then
		rm -rf "$dest.tmp"
		return
	fi
	mv "$dest.tmp" "$dest"
	printf '%s\n' "$dest"
}

mkdir -p "$out_dir/output-styles" "$out_dir/skills"
for persona in "$@"; do
	build_style "$persona"
done
for file in "$root"/team/*.md; do
	[ -f "$file" ] || continue
	build_member "$file"
done
for dir in "$skills_dir"/*/; do
	[ -f "$dir/SKILL.md" ] || continue
	build_skill "${dir%/}"
done
for file in "$claude_dir"/agents/*.md; do
	[ -f "$file" ] || continue
	build_file "$file" "$out_dir/agents/$(basename "$file")"
done
for file in "$claude_dir"/rules/*.md; do
	[ -f "$file" ] || continue
	build_file "$file" "$out_dir/rules/$(basename "$file")"
done
if [ -f "$claude_dir/CLAUDE.md" ]; then
	build_file "$claude_dir/CLAUDE.md" "$out_dir/CLAUDE.md"
fi
for file in "$root"/launchers/konsole/*.colorscheme; do
	[ -f "$file" ] || continue
	build_file "$file" "$out_dir/konsole/$(basename "$file")"
done
# The launchers name the assistant "Kira" when it has no git identity.
for file in "$root"/launchers/*; do
	[ -f "$file" ] || continue
	launcher=$out_dir/bin/$(basename "$file")
	# A subshell: some shells keep an assignment made before a function call.
	(
		KIRA_ASSISTANT_NAME=${assistant_name:-Kira}
		build_file "$file" "$launcher"
	)
	[ ! -f "$launcher" ] || chmod +x "$launcher"
done
