# Ghostty Terminal Support

When SSHing into the server from [Ghostty](https://ghostty.org), programs like `tmux` may fail with:

```
missing or unsuitable terminal: xterm-ghostty
```

This happens because Ghostty sets `TERM=xterm-ghostty`, but the server doesn't have the corresponding terminfo entry.

## Fix: Install terminfo on the server

Create a minimal terminfo file and compile it:

```bash
cat > /tmp/ghostty.terminfo << 'TERMINFO'
xterm-ghostty|Ghostty,
    am, bce, ccc, km, mc5i, mir, msgr, npc, xenl,
    colors#0x100, cols#80, it#8, lines#24, pairs#0x10000,
    use=xterm+256setaf,
    use=xterm+osc104,
    Smulx=\E[4\:%p1%dm,
    use=xterm-256color,
TERMINFO
tic -x /tmp/ghostty.terminfo
rm /tmp/ghostty.terminfo
```

Verify:

```bash
infocmp xterm-ghostty > /dev/null 2>&1 && echo "✅ working" || echo "❌ missing"
```

## Alternative: Ghostty shell integration (client-side)

Ghostty can auto-install terminfo on SSH targets. Add to your Ghostty config (`~/.config/ghostty/config`):

```
shell-integration-features = ssh-terminfo,ssh-env
```

This handles it transparently for all future SSH connections.

## Fallback

If neither option works, override `TERM` in `~/.ssh/config`:

```
Host giskard
    SetEnv TERM=xterm-256color
```

This loses some Ghostty-specific features (undercurl, styled underlines) but is universally compatible.
