## Homebrew

Special thanks to [@beerecca](https://github.com/beerecca) for the initial brew file.

[Homebrew](https://brew.sh/) is "the missing package manager for macOS". Install it first, then run the commands below from this folder.

### Usage

```sh
brew bundle                # install anything missing, upgrade anything outdated
brew bundle check          # is everything in the Brewfile installed and up to date?
brew bundle cleanup        # dry run: what's installed but NOT in the Brewfile?
brew bundle cleanup --force  # uninstall those (and their now-unused dependencies)
```

Run `brew bundle cleanup` (without `--force`) before committing Brewfile changes to catch drift, i.e. things installed by hand that never made it into the Brewfile.

### Brewfile notes

- `cask_args appdir: "~/Applications"` installs apps per-user; `1password` overrides this with `/Applications`, where 1Password expects to be installed (e.g. for its browser integration).
- `greedy: true` (codex, dbeaver-community) makes `brew bundle` upgrade apps that would otherwise update themselves.
- `homebrew/core` and `homebrew/cask` are served from Homebrew's API, so no `tap` lines are needed.

### Why some things are here

Entries whose purpose isn't obvious from the name, or that look unused but aren't:

| Entry | Used by |
|---|---|
| `fastfetch`, `lolcat` | Fish greeting (`fish/config.fish`) |
| `ffmpeg`, `xcodegen`, `xcode-build-server` | iptv-player project |
| `mole` | Mac cleanup tool; the command is `mo` |
| `uv` | Python tooling (`uv tool install` / `uvx` instead of pipx) |
| `jetbrains-toolbox` | Launches Rider, so Rider never shows as "last opened" |
| `visual-studio-code@insiders` | Launched via `code` (see `fish/functions/code.fish`) |
| `font-iosevka` | Ghostty font (`Iosevka Term Extended`) |
| `font-meslo-lg-nerd-font` | VS Code integrated terminal font |
| `font-monaspace` | Kept on purpose, though no config currently references it |

### Not managed here

Installed by their own installers into `~/.local/bin`: `claude`, `codebase-memory-mcp`.
