#!/bin/sh
# Installs rakpak so it can be run from anywhere.
#
#   ./install.sh              copy into ~/.local/share/rakpak, launcher in ~/.local/bin
#   ./install.sh --link       run straight from this checkout instead (edits take effect at once)
#   ./install.sh --prefix DIR install under DIR/share/rakpak and DIR/bin (e.g. /usr/local)
#   ./install.sh --uninstall  remove what a previous run put in place
#
# If the bin folder is not already on your PATH, a line adding it is appended
# to your shell's startup file (bash, zsh or fish) so new shells pick it up.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
prefix="${HOME}/.local"
mode=copy
action=install

while [ $# -gt 0 ]; do
  case "$1" in
    --link) mode=link ;;
    --prefix) prefix="$2"; shift ;;
    --prefix=*) prefix="${1#--prefix=}" ;;
    --uninstall) action=uninstall ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

share="${prefix}/share/rakpak"
bin="${prefix}/bin"
launcher="${bin}/rakpak"

if ! command -v ruby >/dev/null 2>&1; then
  echo "install.sh: ruby is required but was not found on PATH" >&2
  exit 1
fi

if [ "$action" = uninstall ]; then
  rm -f "$launcher"
  rm -rf "$share"
  echo "removed $launcher and $share"
  exit 0
fi

mkdir -p "$bin"
rm -f "$launcher"

if [ "$mode" = link ]; then
  root="$here"
  echo "running from $root"
else
  rm -rf "$share"
  mkdir -p "$share"
  cp -R "${here}/bin" "${here}/lib" "$share/"
  cp "${here}/README.md" "$share/" 2>/dev/null || true
  root="$share"
  echo "installed to $share"
fi
# bin/rakpak (the gem's stub) doesn't set the load path; this wrapper does.
printf '#!/bin/sh\nexec ruby -I "%s/lib" "%s/bin/rakpak" "$@"\n' "$root" "$root" > "$launcher"
chmod +x "$launcher"
echo "created $launcher"

case ":${PATH}:" in
  *":${bin}:"*) on_path=yes ;;
  *) on_path=no ;;
esac

if [ "$on_path" = no ]; then
  shell_name=$(basename "${SHELL:-sh}")
  case "$shell_name" in
    bash) rc="${HOME}/.bashrc";   line="export PATH=\"${bin}:\$PATH\"" ;;
    zsh)  rc="${ZDOTDIR:-$HOME}/.zshrc"; line="export PATH=\"${bin}:\$PATH\"" ;;
    fish) rc="${HOME}/.config/fish/config.fish"; line="fish_add_path ${bin}" ;;
    *)    rc="${HOME}/.profile";  line="export PATH=\"${bin}:\$PATH\"" ;;
  esac
  mkdir -p "$(dirname "$rc")"
  if [ -f "$rc" ] && grep -qF "$line" "$rc"; then
    echo "$rc already adds $bin to PATH"
  else
    printf '\n# added by rakpak install.sh\n%s\n' "$line" >> "$rc"
    echo "added $bin to PATH in $rc"
  fi
  echo "open a new terminal, or run:  $line"
fi

echo "done: run 'rakpak' from anywhere, or 'rakpak -p <folder>' to pack one"
