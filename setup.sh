#!/usr/bin/env bash
set -e

DOTFILES="$(cd "$(dirname "$0")" && pwd)"
OS="$(uname -s)"

# Install Homebrew if missing
unset POSIXLY_CORRECT
if ! command -v brew &>/dev/null; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [[ "$OS" == "Darwin" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  else
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  fi
fi

# Install brew packages
brew bundle --file="$DOTFILES/Brewfile"
[[ "$OS" == "Darwin" ]] && brew bundle --file="$DOTFILES/Brewfile.mac"

# Oh My Zsh
if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

# Oh My Zsh plugins
ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
[[ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]] && \
  git clone https://github.com/zsh-users/zsh-autosuggestions.git "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
[[ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]] && \
  git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
[[ ! -d "$ZSH_CUSTOM/plugins/fast-syntax-highlighting" ]] && \
  git clone https://github.com/zdharma-continuum/fast-syntax-highlighting.git "$ZSH_CUSTOM/plugins/fast-syntax-highlighting"

# Powerlevel10k
[[ ! -d "$ZSH_CUSTOM/themes/powerlevel10k" ]] && \
  git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$ZSH_CUSTOM/themes/powerlevel10k"

# TPM (tmux plugin manager)
[[ ! -d "$HOME/.tmux/plugins/tpm" ]] && \
  git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"

# Backup conflicting files
BACKUP="$HOME/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"
conflicts=$(stow -n -d "$DOTFILES" -t "$HOME" common mac linux 2>&1 | grep 'existing target' | sed 's/.*existing target //' | sed 's/ since.*//' || true)
if [[ -n "$conflicts" ]]; then
  echo "Backing up conflicting files to $BACKUP"
  mkdir -p "$BACKUP"
  while IFS= read -r file; do
    [[ -e "$HOME/$file" ]] || continue
    mkdir -p "$BACKUP/$(dirname "$file")"
    cp -a "$HOME/$file" "$BACKUP/$file"
    rm "$HOME/$file"
  done <<< "$conflicts"
fi

# Stow packages
echo "Stowing common..."
stow -v -R -d "$DOTFILES" -t "$HOME" common

if [[ "$OS" == "Darwin" ]]; then
  echo "Stowing mac..."
  stow -v -R -d "$DOTFILES" -t "$HOME" mac
else
  echo "Stowing linux..."
  stow -v -R -d "$DOTFILES" -t "$HOME" linux
fi

echo "Done! Restart your shell or run: source ~/.zshrc"
