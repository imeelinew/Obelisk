#!/bin/zsh
set -euo pipefail

# Build and verify a signed Release before stopping the installed application.
script_dir="${0:A:h}"
repo_root="${script_dir:h}"
app_name="Obelisk"
installed_app="/Applications/${app_name}.app"
stage_dir=""
restart_needed=0

cleanup() {
    local result=$?
    if (( result != 0 && restart_needed )); then
        print -u2 "Install failed; reopening the available installed application"
        /usr/bin/open "$installed_app" || true
    fi
    [[ -z "$stage_dir" ]] || /bin/rm -rf -- "$stage_dir"
    return "$result"
}
trap cleanup EXIT

[[ ! -L "$installed_app" ]] || {
    print -u2 "Installed application must not be a symlink: $installed_app"
    exit 65
}
mkdir -p "$repo_root/DerivedData"
stage_dir=$(mktemp -d "$repo_root/DerivedData/.install.XXXXXX")
staged_app="$stage_dir/${app_name}.app"

print "Building and signing Release"
"$script_dir/sign.sh" --build --output "$staged_app"
codesign --verify --all-architectures --deep --strict "$staged_app"
python3 - "$staged_app" <<'PYCODE'
import plistlib, subprocess, sys
app = sys.argv[1]
r = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", app],
                   capture_output=True, check=True)
entitlements = plistlib.loads(r.stdout) if r.stdout.strip() else {}
if entitlements.get("com.apple.security.get-task-allow"):
    raise SystemExit("Release unexpectedly permits debugging; installation stopped")
r = subprocess.run(["codesign", "-dvv", app], capture_output=True, check=True)
if b"(runtime)" not in r.stderr:
    raise SystemExit("Release does not enable Hardened Runtime; installation stopped")
PYCODE

if pgrep -xq "$app_name"; then
    restart_needed=1
    print "Quitting $app_name"
    osascript -e "tell application \"$app_name\" to quit" >/dev/null 2>&1 || true
    for _ in {1..20}; do
        pgrep -xq "$app_name" || break
        sleep 0.5
    done
    if pgrep -xq "$app_name"; then
        killall "$app_name"
        for _ in {1..20}; do
            pgrep -xq "$app_name" || break
            sleep 0.1
        done
        if pgrep -xq "$app_name"; then
            print -u2 "$app_name is still running; installation stopped"
            exit 70
        fi
    fi
fi

print "Installing verified Release"
"$script_dir/sign.sh" --app "$staged_app" --output "$installed_app" \
    --report "${MAC_SIGN_REPORT:-$repo_root/DerivedData/local-signing.json}"
codesign --verify --all-architectures --deep --strict "$installed_app"
print "Launching $app_name"
/usr/bin/open "$installed_app"
restart_needed=0
