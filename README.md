<p align="center">
  <img src="https://res.cloudinary.com/noqoikpl/image/upload/f_auto,q_auto/rakpak-upper" alt="rakpak" width="520">
</p>

<p align="center">
  <a href="https://github.com/eof0/rakpak/actions/workflows/ci.yml"><img src="https://github.com/eof0/rakpak/actions/workflows/ci.yml/badge.svg" alt="tests"></a>
  <a href="https://rubygems.org/gems/rakpak"><img src="https://img.shields.io/gem/v/rakpak" alt="gem version"></a>
  <a href="https://rubygems.org/gems/rakpak"><img src="https://img.shields.io/gem/dt/rakpak" alt="downloads"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/eof0/rakpak" alt="license"></a>
</p>

<p align="center">Tag files and folders anywhere on your filesystem, then archive them all at once, or unpack one you already have.</p>

You walk around, press `space` on anything you want, press `p`, answer a few
questions, and it builds the archive. The progress view can be sent to the
background while you keep browsing. Press `u` on an archive instead and it
unpacks, wherever you want it.

Needs Ruby 3.0 or newer and nothing else.

## Install

```
gem install rakpak
```

Then `rakpak` from any folder. If your shell cannot find it afterwards, the
folder RubyGems puts executables in is not on your PATH; `gem env` shows it
under EXECUTABLE DIRECTORY.

Without RubyGems, clone this repo and run `./install.sh`. That copies the
program to `~/.local/share/rakpak` and puts a launcher in `~/.local/bin`,
adding that folder to your shell startup file if it is not on your PATH yet.
`./install.sh --link` runs straight from the checkout so edits take effect at
once, `--prefix /usr/local` installs system-wide, and `--uninstall` removes it.

```
rakpak                    browse from your home folder
rakpak ~/Documents        browse from there instead
rakpak .                  browse from the current folder
rakpak -p ~/Documents     pack that folder: opens on the archive prompts
rakpak -p a.txt b/ c      pack several things at once
rakpak -d site.tar.gz     unpack it here and now, into site/
rakpak -d a.tgz b.zip     unpack several, each into its own folder
```

## Starting up

With no arguments rakpak opens in your home folder: its contents in the
middle pane, the folder above it on the left, a preview of whatever is under
the cursor on the right. Give it a folder and it opens there instead.

`-p` (or `--pack`) skips the browsing. Every path you give is tagged, the
browser opens on the folder holding the first one with the cursor resting on
it, and the archive prompts appear at once, starting with the kind of archive
and its compression. The archive is written next to that first path. Press
`esc` on any prompt and you are back in the browser with the tags still set.

`-d` (or `--depack`) does not open the browser at all. Each archive is
unpacked straight into the folder you are standing in, the way `tar` would,
each one into a folder of its own name: `site.tar.gz` gives you `site/`.
A lone compressed file has nothing to wrap, so `notes.txt.gz` lands
beside you as `notes.txt`. One bad archive does not stop the rest, and the
exit status is non-zero if any of them failed.

## The flow

1. **Browse and tag.** Vim keys or arrows. `space` tags whatever is under the
   cursor and moves down. Tags persist as you walk, so you can pick something in
   `~/Documents`, walk to `/etc`, and tag more. `T` reviews everything tagged.
   `t` opens a queue pane on the far left that stays up while you browse. It
   lists each queued item by name, where it lives, and its size, with the
   running total on top.
2. **`p` to pack.** Choose *compressed tarball* (the default), *plain
   tarball*, or *zip archive*.
3. **Set the flags.** Compression method, level, and the switches for that
   format. Compressed tarballs default to gzip, the one every system can
   read.
4. **Leave things out.** Type names separated by commas, like
   `node_modules, .cache, *.log`. Each one is left out wherever it turns
   up, along with everything inside it. Or pick *Tag files and directories*
   to walk the folders you are packing and press `space` on the exact spots
   to skip; `p` brings you back. Skipped when only files are packed.
5. **Say where.** This directory, your home directory, or one you type
   into the field right there. `~`, `$HOME` and absolute paths all work,
   and typing anything jumps to the field.
6. **Name it.** The extension is added for you.
7. **Confirm.** You see the exact command before anything runs. Only `enter`
   starts it.
8. **Watch it, or press `b`** to drop it into the background and keep browsing.

If nothing is tagged, `p` archives whatever the cursor is on.

## Unpacking

`u` on an archive opens three prompts: which folder to unpack into, what to
call the folder it makes there, and the usual confirm screen showing the
exact command.

Unlike `p`, this follows the cursor rather than the tag set: one archive, one
destination. The folder is offered as the archive's own name with the
extension taken off, so `site.tar.gz` suggests `site/`, which means nothing
is ever sprayed across the folder you are standing in. Type `.` as
the name to unpack straight into the folder you picked instead, and the
folder prompt takes `~`, `$HOME` and any absolute path, so the contents can
go anywhere. A lone compressed file skips the folder entirely.

If the destination already has files in it, the confirm screen says so before
anything runs. A failed extraction leaves whatever it managed to write; the
files that were already there are never touched.

## Keys

| | |
|---|---|
| `j` `k` `↑` `↓` | move (wraps at either end) |
| `l` `→` `enter` | enter folder |
| `h` `←` | leave folder |
| `gg` `G` | top / bottom |
| `ctrl-d` `ctrl-u` | half page |
| `gh` `~` / `gr` | home / root |
| `space` | tag or untag, then move down |
| `x` | exclude or include, then move down: left out of anything packed around it |
| `a` / `d` | tag / untag everything in this folder |
| `D` | clear all tags and exclusions |
| `T` | review tagged items (`space` removes) |
| `t` | show or hide the queue pane |
| `/` | filter this folder |
| `.` | show hidden files |
| `ctrl-r` | reload |
| `p` | pack: archive what is tagged |
| `u` | unpack the archive under the cursor |
| `b` | watch a running job |
| `?` | all keys |
| `q` | quit |

In the job view: `b` backgrounds it, `x` cancels, `esc` returns to the
browser, `q` quits.

## Formats

Every run produces exactly one file.

**Compressed tarball**: `tar` piped through `gzip`, `zstd`, `xz`, `bzip2`,
`lz4` or `brotli`, giving `.tar.gz`, `.tar.zst` and so on. Each has a level,
and the tar switches (permissions, xattrs, symlink handling, VCS exclusion,
reproducible ordering, and so on) are on the same screen.

**Plain tarball**: a bare `.tar`, no compression. Just the tar switches.

**Zip archive**: a `.zip` written by Info-ZIP with deflate, bzip2 or store.
When exactly one file is selected, the single-file compressors are offered
here too, so `notes.txt` becomes `notes.txt.gz` or `notes.txt.zst` without a
tarball around it. For a folder those are greyed out with the reason, since
`gzip` alone cannot take a folder.

Every one of those can be read back: `.tar`, `.tar.gz`, `.tar.zst`, `.tar.xz`,
`.tar.bz2`, `.tar.lz4`, `.tar.br`, the `.tgz`, `.tzst`, `.txz` and `.tbz2`
short forms, `.zip` via `unzip`, and `.gz`, `.zst`, `.xz`, `.bz2`, `.lz4` or
`.br` on their own.

Everything is probed at startup: `PATH` for the compressors, `tar --version` to
tell GNU tar from bsdtar from busybox, and `zip -v` for its compiled-in methods.
Anything that will not work on this machine is greyed out with the reason.
Unpacking a `.zip` wants `unzip`, which is a different program from the `zip`
used to write one, so it is checked on its own.

## How the archive is shaped

Members are stored relative to the deepest folder that contains every tagged
path, which is shown on the confirm screen. Tag `~/a/b` and `~/c` and the
archive holds `a/b` and `c`.

## Notes

- Commands are run directly, not in a shell. Filenames containing spaces,
  quotes, `$`, `;` or a leading `-` are safe.
- Cancelling kills the whole process group, so the compressor goes too. A
  cancelled pack removes its half-written archive; a cancelled unpack leaves
  the files it had already extracted, since deleting a folder is not
  rakpak's call to make.
- Folder sizes are counted in the background. A folder too large to finish
  counting in a few seconds shows `≥`, meaning the real size is at least that.

## Tests

```
ruby test/test_rakpak.rb
```
