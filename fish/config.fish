fish_add_path /opt/homebrew/bin ~/.local/bin

if status is-interactive
    fastfetch | lolcat
end

# pnpm
set -gx PNPM_HOME "/Users/rparkar/Library/pnpm"
if not string match -q -- $PNPM_HOME $PATH
  set -gx PATH "$PNPM_HOME" $PATH
end
# pnpm end

# bun
set --export BUN_INSTALL "$HOME/.bun"
set --export PATH $BUN_INSTALL/bin $PATH
