# Clipboard

To copy text to the local clipboard, pipe data to the appropriate command.

## Local shells
- macOS: `echo "text" | pbcopy`
- Linux (X11): `echo "text" | xclip -selection clipboard`
- Windows: `echo "text" | clip`
- WSL2: `echo "text" | clip.exe`

## SSH / remote shells
When running over SSH, use OSC 52 to write to the local clipboard:

`echo "text" | printf '\e]52;c;%s\a' "$(base64 | tr -d '\n')"`
