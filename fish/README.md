## Fish

Only hand-written config lives here. Plugin files ([fisher](https://github.com/jorgebucaran/fisher), tide, nvm.fish) and `fish_variables` stay untracked in `~/.config/fish`: fisher reinstalls plugins from `fish_plugins`, and `fish_variables` is machine state that fish rewrites constantly.

### Setup on a new machine

```fish
mkdir -p ~/.config/fish/functions
ln -s ~/Projects/dotfiles/fish/config.fish ~/.config/fish/config.fish
ln -s ~/Projects/dotfiles/fish/fish_plugins ~/.config/fish/fish_plugins
ln -s ~/Projects/dotfiles/fish/functions/code.fish ~/.config/fish/functions/code.fish

curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher update
tide configure   # prompt layout lives in fish_variables, so it's chosen per machine
```
