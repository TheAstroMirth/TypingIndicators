#!/bin/bash
# TypingIndicators - https://github.com/TheAstroMirth/TypingIndicators
# Installer scripts: Copyright (c) 2026 TheAstroMirth.
# Licensed under the GNU General Public License v3.0. See LICENSE and NOTICE.md.
#
# Shared helpers for the TypingIndicators macOS installer and uninstaller.
# Sourced by install.sh and uninstall.sh. Written for the bash 3.2 that ships with macOS.
# shellcheck disable=SC2034,SC2088

PLUGIN_NAME="TypingIndicators"
PLUGIN_FILES="index.tsx style.css"
BACKUP_ROOT="${TI_BACKUP_ROOT:-$HOME/Library/Application Support/TypingIndicators/backups}"

VENCORD_DOCS="https://docs.vencord.dev/installing/"
VENCORD_PLUGIN_DOCS="https://docs.vencord.dev/installing/custom-plugins/"
EQUICORD_DOCS="https://github.com/Equicord/Equicord#installing-equicord-devbuild"

# Set by parse_args
OPT_CLIENT=""
OPT_SOURCE=""
OPT_YES=0
OPT_NO_BUILD=0

# Set by select_client / select_checkout
CLIENT=""            # vencord | equicord
CLIENT_LABEL=""      # Vencord | Equicord
CLIENT_DOCS=""
REPO=""              # root of the source folder

# Set by check_checkout
FOUND_ROOT=""
FOUND_CLIENT=""
CHECK_REASON=""

if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BOLD=""; C_DIM=""; C_OFF=""
fi

step() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$1" "$C_OFF"; }
info() { printf '   %s\n' "$1"; }
ok()   { printf ' %s+%s %s\n' "$C_GREEN" "$C_OFF" "$1"; }
warn() { printf ' %s!%s %s\n' "$C_YELLOW" "$C_OFF" "$1"; }
fail() { printf ' %sx%s %s\n' "$C_RED" "$C_OFF" "$1" >&2; }

die() {
    fail "$1"
    printf '\n%s%s stopped. Nothing else was changed.%s\n' "$C_RED" "$SCRIPT_TITLE" "$C_OFF" >&2
    exit 1
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --client)   shift; OPT_CLIENT="${1:-}" ;;
            --client=*) OPT_CLIENT="${1#--client=}" ;;
            --source)   shift; OPT_SOURCE="${1:-}" ;;
            --source=*) OPT_SOURCE="${1#--source=}" ;;
            --yes|-y)   OPT_YES=1 ;;
            --no-build) OPT_NO_BUILD=1 ;;
            --help|-h)  usage; exit 0 ;;
            *) fail "Unknown option: $1"; usage; exit 2 ;;
        esac
        shift
    done
}

# ask "Question" default(y|n)  -> returns 0 for yes
ask() {
    local prompt="$1" def="$2" hint reply
    if [ "$def" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    if [ "$OPT_YES" = "1" ]; then
        [ "$def" = "y" ]; return
    fi
    printf '   %s %s ' "$prompt" "$hint"
    IFS= read -r reply || reply=""
    case "$reply" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        [Nn]|[Nn][Oo])     return 1 ;;
        *) [ "$def" = "y" ] ;;
    esac
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

require_macos() {
    if [ "$(uname -s)" != "Darwin" ] && [ -z "${TI_ALLOW_NON_MACOS:-}" ]; then
        die "This script is for macOS. On Windows use installers\\windows\\install.bat."
    fi
}

# Double-clicked .command files do not always get the PATH from ~/.zshrc,
# so add the usual places Node, pnpm and Git live. Nothing is installed here.
extend_path() {
    local d
    for d in /opt/homebrew/bin /usr/local/bin "$HOME/Library/pnpm" "$HOME/.local/share/pnpm" \
             "$HOME/.volta/bin" "$HOME/.asdf/shims" "$HOME/.local/share/mise/shims" "$HOME/.local/bin"; do
        if [ -d "$d" ]; then
            case ":$PATH:" in *":$d:"*) ;; *) PATH="$PATH:$d" ;; esac
        fi
    done
    if ! command -v node >/dev/null 2>&1; then
        if [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
            # shellcheck disable=SC1090,SC1091
            . "${NVM_DIR:-$HOME/.nvm}/nvm.sh" >/dev/null 2>&1
        elif command -v fnm >/dev/null 2>&1; then
            eval "$(fnm env 2>/dev/null)"
        fi
    fi
    export PATH
}

# ------------------------------------------------------------------ client

set_client() {
    CLIENT="$1"
    if [ "$CLIENT" = "equicord" ]; then
        CLIENT_LABEL="Equicord"; CLIENT_DOCS="$EQUICORD_DOCS"
    else
        CLIENT_LABEL="Vencord"; CLIENT_DOCS="$VENCORD_DOCS"
    fi
}

select_client() {
    local reply
    if [ -n "$OPT_CLIENT" ]; then
        case "$(lower "$OPT_CLIENT")" in
            vencord)  set_client vencord ;;
            equicord) set_client equicord ;;
            *) die "Unknown client '$OPT_CLIENT'. Use --client vencord or --client equicord." ;;
        esac
    elif [ "$OPT_YES" = "1" ]; then
        die "With --yes you must also pass --client vencord or --client equicord."
    else
        info "Which client do you use?"
        info "  [1] Vencord"
        info "  [2] Equicord"
        while :; do
            printf '   Choose 1 or 2 (q to quit): '
            IFS= read -r reply || die "No client selected."
            case "$(lower "$reply")" in
                1|vencord)  set_client vencord; break ;;
                2|equicord) set_client equicord; break ;;
                q|quit)     die "No client selected." ;;
            esac
        done
    fi
    ok "Client: $CLIENT_LABEL"
}

# ---------------------------------------------------------------- checkouts

# Prints "vencord" or "equicord" when the folder looks like the root of a
# source folder of that project. A package.json alone is not enough.
checkout_client() {
    local dir="$1" name
    [ -f "$dir/package.json" ] || return 1
    [ -d "$dir/src/plugins" ] || return 1
    [ -f "$dir/scripts/build/build.mjs" ] || return 1
    name=$(sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$dir/package.json" | head -n 1)
    case "$name" in
        vencord)  printf 'vencord\n'; return 0 ;;
        equicord) [ -d "$dir/src/equicordplugins" ] || return 1
                  printf 'equicord\n'; return 0 ;;
    esac
    return 1
}

# Accepts the repository root, its src folder, src/userplugins (or a folder
# below that) and prints the repository root.
find_checkout_root() {
    local dir="$1" i=0
    [ -d "$dir" ] || return 1
    dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
    while [ $i -lt 4 ] && [ -n "$dir" ] && [ "$dir" != "/" ]; do
        if checkout_client "$dir" >/dev/null; then
            printf '%s\n' "$dir"; return 0
        fi
        dir=$(dirname "$dir")
        i=$((i + 1))
    done
    return 1
}

# check_checkout PATH
# Returns 0 and sets FOUND_ROOT when PATH is a usable source folder for $CLIENT.
# Otherwise returns 1 (not a source folder), 2 (the other client) or
# 3 (not a git clone) and sets CHECK_REASON. FOUND_CLIENT is set for 0, 2, 3.
check_checkout() {
    local path="$1"
    FOUND_ROOT=""; FOUND_CLIENT=""; CHECK_REASON=""
    if [ ! -d "$path" ]; then
        CHECK_REASON="That folder does not exist: $path"
        return 1
    fi
    if ! FOUND_ROOT=$(find_checkout_root "$path"); then
        FOUND_ROOT=""
        CHECK_REASON="That is not a Vencord or Equicord source folder: $path"
        return 1
    fi
    FOUND_CLIENT=$(checkout_client "$FOUND_ROOT")
    if [ ! -e "$FOUND_ROOT/.git" ]; then
        CHECK_REASON="$FOUND_ROOT is not a Git checkout (it looks like a downloaded zip)."
        return 3
    fi
    if [ "$FOUND_CLIENT" != "$CLIENT" ]; then
        CHECK_REASON="That is a source folder of the other client, not $CLIENT_LABEL: $FOUND_ROOT"
        return 2
    fi
    return 0
}

# Turns what a user typed or dragged into Terminal into a plain path.
clean_path() {
    local p="$1"
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    case "$p" in
        \"*\") p="${p#\"}"; p="${p%\"}" ;;
        \'*\') p="${p#\'}"; p="${p%\'}" ;;
        *) p=$(printf '%s' "$p" | sed 's/\\\(.\)/\1/g') ;;
    esac
    case "$p" in
        "~")   p="$HOME" ;;
        "~/"*) p="$HOME/${p#\~/}" ;;
    esac
    printf '%s\n' "$p"
}

explain_source_needed() {
    echo
    warn "A $CLIENT_LABEL source folder is required."
    info "Custom plugins cannot be added to the normal installer version of $CLIENT_LABEL."
    info "They are built from the source code, so you need a source folder"
    info "(a 'git clone' of $CLIENT_LABEL) on this Mac first."
    info "This installer does not download, clone or install $CLIENT_LABEL for you."
    echo
    info "Official guide:"
    if [ "$CLIENT" = "equicord" ]; then
        info "  $EQUICORD_DOCS"
    else
        info "  $VENCORD_DOCS"
        info "  $VENCORD_PLUGIN_DOCS"
    fi
    info "Set it up, then run this again."
}

explain_expected_folder() {
    info "A source folder contains package.json, a src/plugins folder and"
    info "scripts/build/build.mjs. You can give the folder itself, its 'src' folder"
    info "or its 'src/userplugins' folder."
}

# Sets REPO (and may switch CLIENT if the user agrees) or exits.
select_checkout() {
    local reply picked rc other

    if [ -n "$OPT_SOURCE" ]; then
        check_checkout "$(clean_path "$OPT_SOURCE")"
        rc=$?
        if [ $rc -ne 0 ]; then
            fail "$CHECK_REASON"
            [ $rc -eq 1 ] && explain_expected_folder
            [ $rc -eq 3 ] && info "The source folder must be a 'git clone', see $CLIENT_DOCS"
            die "The folder passed with --source cannot be used."
        fi
        REPO="$FOUND_ROOT"
        ok "Using $CLIENT_LABEL source folder: $REPO"
        return 0
    fi

    [ "$OPT_YES" = "1" ] && die "With --yes you must also pass --source \"/path/to/folder\"."

    if ! ask "Do you already have a $CLIENT_LABEL source folder (a git clone) on this Mac?" y; then
        explain_source_needed
        die "No source folder available."
    fi

    while :; do
        echo
        info "Drag your $CLIENT_LABEL source folder into this window and press Return."
        info "Or press Return on an empty line to open a folder picker. Type q to quit."
        printf '   Folder: '
        IFS= read -r reply || die "No source folder selected."
        case "$reply" in q|Q|quit) die "No source folder selected." ;; esac
        if [ -z "$reply" ]; then
            picked=""
            if command -v osascript >/dev/null 2>&1; then
                picked=$(osascript -e 'POSIX path of (choose folder with prompt "Select your Vencord or Equicord source folder")' 2>/dev/null) || picked=""
            fi
            [ -n "$picked" ] || { warn "No folder selected."; continue; }
        else
            picked=$(clean_path "$reply")
        fi

        check_checkout "$picked"
        rc=$?
        case $rc in
            0)  REPO="$FOUND_ROOT"; break ;;
            2)  warn "$CHECK_REASON"
                if [ "$FOUND_CLIENT" = "equicord" ]; then other="Equicord"; else other="Vencord"; fi
                if ask "That folder is $other. Use it and continue with $other instead?" y; then
                    set_client "$FOUND_CLIENT"
                    REPO="$FOUND_ROOT"
                    break
                fi
                info "Choose another folder." ;;
            3)  warn "$CHECK_REASON"
                info "The source folder must be a 'git clone', see $CLIENT_DOCS"
                info "Choose another folder." ;;
            *)  warn "$CHECK_REASON"
                explain_expected_folder ;;
        esac
    done
    ok "Using $CLIENT_LABEL source folder: $REPO"
}

# ------------------------------------------------------------ prerequisites

# check_tools  -> returns 0 when Git, Node.js and pnpm are usable.
check_tools() {
    local missing=0
    # On a Mac without the Xcode Command Line Tools, /usr/bin/git is only a
    # placeholder that opens an install prompt, so check for the tools first.
    if [ "$(command -v git 2>/dev/null)" = "/usr/bin/git" ] && command -v xcode-select >/dev/null 2>&1 \
        && ! xcode-select -p >/dev/null 2>&1; then
        fail "Git was not found (the Xcode Command Line Tools are not installed)."
        info "Install it with:  xcode-select --install   (or from https://git-scm.com/download/mac)"
        missing=1
    elif command -v git >/dev/null 2>&1; then
        ok "Git found ($(git --version 2>/dev/null | sed 's/^git version //'))"
    else
        fail "Git was not found."
        info "Install it with:  xcode-select --install   (or from https://git-scm.com/download/mac)"
        missing=1
    fi
    if command -v node >/dev/null 2>&1; then
        ok "Node.js found ($(node -v 2>/dev/null))"
    else
        fail "Node.js was not found."
        info "Install the LTS version from https://nodejs.org/ (or 'brew install node')."
        missing=1
    fi
    if command -v pnpm >/dev/null 2>&1; then
        ok "pnpm found ($(pnpm --version 2>/dev/null))"
    else
        fail "pnpm was not found."
        info "Install it with:  npm install -g pnpm   (or 'corepack enable')"
        missing=1
    fi
    if [ "$missing" -ne 0 ]; then
        info "Nothing is installed for you. Install what is missing, open a new"
        info "Terminal window and run this again."
        return 1
    fi
    return 0
}

# Compares the installed Node.js with what the source folder asks for.
check_node_version() {
    local want have
    have=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)
    want=$(sed -n 's/.*"node"[[:space:]]*:[[:space:]]*"[^0-9"]*\([0-9][0-9]*\).*/\1/p' "$REPO/package.json" 2>/dev/null | head -n 1)
    if [ -n "$want" ] && [ -n "$have" ] && [ "$have" -lt "$want" ] 2>/dev/null; then
        fail "Node.js $(node -v 2>/dev/null) is too old. This $CLIENT_LABEL source folder needs Node.js $want or newer."
        info "Get the current LTS from https://nodejs.org/"
        return 1
    fi
    return 0
}

# Returns 0 when dependencies are ready for a build.
check_dependencies() {
    local rc
    if [ -d "$REPO/node_modules" ]; then
        ok "$CLIENT_LABEL dependencies are installed (node_modules)"
        return 0
    fi
    warn "$CLIENT_LABEL dependencies are not installed yet (no node_modules folder)."
    info "They are needed to build. The step for this is: pnpm install --frozen-lockfile"
    if ask "Run it now in $REPO?" y; then
        ( cd "$REPO" && pnpm install --frozen-lockfile )
        rc=$?
        [ $rc -eq 0 ] || { fail "pnpm install failed (exit code $rc). See the output above."; return 1; }
        ok "Dependencies installed"
        return 0
    fi
    info "Skipped. Without the dependencies the build cannot run."
    return 1
}

# Returns 0 only if the build really succeeded.
run_build() {
    local rc
    info "Running: pnpm build   (in $REPO)"
    echo
    ( cd "$REPO" && pnpm build )
    rc=$?
    echo
    if [ $rc -ne 0 ]; then
        fail "The build FAILED (pnpm build exit code $rc). See the output above."
        return 1
    fi
    ok "Build finished"
    return 0
}

# ------------------------------------------------------------------ plugin

# Prints the path of an existing TypingIndicators entry in src/userplugins,
# whatever its letter case (macOS file systems usually ignore case).
find_existing_plugin() {
    local userplugins="$1" e want
    want=$(lower "$PLUGIN_NAME")
    [ -d "$userplugins" ] || return 1
    for e in "$userplugins"/*; do
        [ -e "$e" ] || [ -L "$e" ] || continue
        if [ "$(lower "$(basename "$e")")" = "$want" ]; then
            printf '%s\n' "$e"
            return 0
        fi
    done
    return 1
}

# ------------------------------------------------------------ small helpers

exists() { [ -e "$1" ] || [ -L "$1" ]; }

# Removes one entry. For a link only the link is removed, never its target.
remove_entry() {
    [ -n "$1" ] && [ "$1" != "/" ] || return 1
    if [ -L "$1" ] || [ ! -d "$1" ]; then rm -f "${1:?}"; else rm -rf "${1:?}"; fi
}

# Working names inside src/userplugins: .TypingIndicators.<kind>.<pid>
# The Vencord and Equicord builds ignore entries that start with a dot.
stage_path() { printf '%s/.%s.%s.%s\n' "$1" "$PLUGIN_NAME" "$2" "$$"; }

# Prints one "checksum size ./path" line per file below a folder.
tree_manifest() {
    ( cd "$1" 2>/dev/null || exit 1
      find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do
          cksum "$f" || exit 1
      done )
}

# Tells the user about working folders left behind by a run that was killed
# before it could clean up. Nothing is deleted here.
# report_leftovers USERPLUGINS  -> sets LEFTOVER_OLD to the only previous copy, if exactly one.
report_leftovers() {
    local userplugins="$1" e n=0
    LEFTOVER_OLD=""
    [ -d "$userplugins" ] || return 0
    for e in "$userplugins"/."$PLUGIN_NAME".*.*; do
        exists "$e" || continue
        case "$(basename "$e")" in
            ."$PLUGIN_NAME".old.*)
                n=$((n + 1)); LEFTOVER_OLD="$e"
                warn "An earlier run was interrupted. It left the PREVIOUS plugin folder here:"
                info "  $e"
                info "To get it back by hand: remove '$PLUGIN_NAME' next to it (if there is one)"
                info "and rename this folder to '$PLUGIN_NAME'. Delete it if you do not need it." ;;
            *)
                warn "An earlier run was interrupted. It left an incomplete working copy here:"
                info "  $e"
                info "It is not used by $CLIENT_LABEL and can be deleted." ;;
        esac
    done
    [ "$n" -eq 1 ] || LEFTOVER_OLD=""
    return 0
}

# ----------------------------------------------------------------- backups

# backup_plugin EXISTING_PATH  -> sets BACKUP_DIR. Never reuses a folder.
# backup-info.txt is written last, so a backup that was cut short is never
# listed or offered for restoring.
backup_plugin() {
    local existing="$1" stamp base n=1 kind="folder"
    stamp=$(date +%Y-%m-%d_%H-%M-%S)
    mkdir -p "$BACKUP_ROOT" || return 1
    base="$BACKUP_ROOT/$stamp"
    BACKUP_DIR="$base"
    while ! mkdir "$BACKUP_DIR" 2>/dev/null; do
        n=$((n + 1))
        [ $n -le 50 ] || return 1
        BACKUP_DIR="$base-$n"
    done
    cp -RPp "$existing" "$BACKUP_DIR/$PLUGIN_NAME" || return 1
    if [ -L "$existing" ]; then
        kind="link"
    elif [ -d "$existing" ]; then
        diff -r "$existing" "$BACKUP_DIR/$PLUGIN_NAME" >/dev/null 2>&1 || return 1
        tree_manifest "$BACKUP_DIR/$PLUGIN_NAME" > "$BACKUP_DIR/backup-manifest.txt" || return 1
    else
        kind="file"
        cmp -s "$existing" "$BACKUP_DIR/$PLUGIN_NAME" || return 1
    fi
    {
        printf 'client=%s\n' "$CLIENT"
        printf 'source=%s\n' "$REPO"
        printf 'original=%s\n' "$existing"
        printf 'created=%s\n' "$stamp"
        printf 'kind=%s\n' "$kind"
    } > "$BACKUP_DIR/backup-info.txt" || return 1
    return 0
}

backup_field() {
    sed -n "s/^$2=//p" "$1/backup-info.txt" 2>/dev/null | head -n 1
}

# True when the backup was taken from exactly this source folder and client.
backup_is_ours() {
    [ -f "$1/backup-info.txt" ] || return 1
    [ "$(backup_field "$1" client)" = "$CLIENT" ] || return 1
    [ "$(backup_field "$1" source)" = "$REPO" ] || return 1
    exists "$1/$PLUGIN_NAME"
}

# Prints the backups taken from $REPO for $CLIENT, newest first, one per line.
list_backups() {
    local d
    [ -d "$BACKUP_ROOT" ] || return 0
    for d in "$BACKUP_ROOT"/*; do
        backup_is_ours "$d" || continue
        printf '%s\n' "$d"
    done | sort -r
}

# Prints how many complete backups belong to another source folder or client.
count_other_backups() {
    local d n=0
    if [ -d "$BACKUP_ROOT" ]; then
        for d in "$BACKUP_ROOT"/*; do
            [ -f "$d/backup-info.txt" ] || continue
            backup_is_ours "$d" || n=$((n + 1))
        done
    fi
    printf '%s\n' "$n"
}

# validate_backup DIR -> 0 when the backup can be restored into $REPO.
# Sets BACKUP_PROBLEM (why not) and BACKUP_NOTE (a remark for a usable backup).
validate_backup() {
    local d="$1" p="$1/$PLUGIN_NAME" entry=""
    BACKUP_PROBLEM=""; BACKUP_NOTE=""
    if [ ! -f "$d/backup-info.txt" ]; then
        BACKUP_PROBLEM="it has no backup-info.txt, so it is incomplete"; return 1
    fi
    if [ "$(backup_field "$d" client)" != "$CLIENT" ]; then
        BACKUP_PROBLEM="it was made for another client"; return 1
    fi
    if [ "$(backup_field "$d" source)" != "$REPO" ]; then
        BACKUP_PROBLEM="it was taken from another source folder ($(backup_field "$d" source))"; return 1
    fi
    if [ -L "$p" ]; then
        BACKUP_PROBLEM="it holds a link (to $(readlink "$p")), not plugin files. Recreate the link by hand if you still want it"; return 1
    fi
    if [ ! -d "$p" ]; then
        BACKUP_PROBLEM="it does not hold a $PLUGIN_NAME folder"; return 1
    fi
    if [ -n "$(find "$p" -type l -print 2>/dev/null | head -n 1)" ]; then
        BACKUP_PROBLEM="it contains links to other places"; return 1
    fi
    for entry in index.tsx index.ts; do
        [ -f "$p/$entry" ] && [ -s "$p/$entry" ] && break
        entry=""
    done
    if [ -z "$entry" ]; then
        BACKUP_PROBLEM="it has no index.tsx, so it is not a usable plugin folder"; return 1
    fi
    if [ -f "$d/backup-manifest.txt" ]; then
        if [ "$(tree_manifest "$p")" != "$(cat "$d/backup-manifest.txt")" ]; then
            BACKUP_PROBLEM="its files no longer match the checksums recorded when it was made"; return 1
        fi
    else
        BACKUP_NOTE="no checksum list was recorded for it, so only its structure was checked"
    fi
    return 0
}

# restore_backup DIR USERPLUGINS -> copies the backup to a working folder, checks
# the copy, moves it into place in one step and checks it again.
# RESTORE_STAGE names the working folder while it exists.
RESTORE_STAGE=""
restore_backup() {
    local d="$1" userplugins="$2" dest="$2/$PLUGIN_NAME" p="$1/$PLUGIN_NAME"
    RESTORE_ERROR=""
    if exists "$dest"; then
        RESTORE_ERROR="a $PLUGIN_NAME folder is already in place"; return 1
    fi
    mkdir -p "$userplugins" || { RESTORE_ERROR="could not create $userplugins"; return 1; }
    RESTORE_STAGE=$(stage_path "$userplugins" restore)
    if exists "$RESTORE_STAGE"; then
        RESTORE_ERROR="a working folder is in the way: $RESTORE_STAGE"; RESTORE_STAGE=""; return 1
    fi
    if ! cp -RPp "$p" "$RESTORE_STAGE" || ! diff -r "$p" "$RESTORE_STAGE" >/dev/null 2>&1; then
        remove_entry "$RESTORE_STAGE"; RESTORE_STAGE=""
        RESTORE_ERROR="the copy could not be made or did not match the backup"; return 1
    fi
    if ! mv "$RESTORE_STAGE" "$dest"; then
        remove_entry "$RESTORE_STAGE"; RESTORE_STAGE=""
        RESTORE_ERROR="the restored copy could not be moved into place"; return 1
    fi
    RESTORE_STAGE=""
    if ! diff -r "$p" "$dest" >/dev/null 2>&1; then
        remove_entry "$dest"
        RESTORE_ERROR="the restored files did not match the backup and were removed again"; return 1
    fi
    if [ -f "$d/backup-manifest.txt" ] && [ "$(tree_manifest "$dest")" != "$(cat "$d/backup-manifest.txt")" ]; then
        remove_entry "$dest"
        RESTORE_ERROR="the restored files did not match the recorded checksums and were removed again"; return 1
    fi
    return 0
}
