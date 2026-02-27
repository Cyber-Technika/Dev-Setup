# CyTechnika Prompt v1.4
# Structured • High-signal • Monokai Classic • Nerd Font home marker

autoload -U colors && colors

RED_B="%{$fg_bold[red]%}"
GRN_B="%{$fg_bold[green]%}"
YLW_B="%{$fg_bold[yellow]%}"
CYN="%{$fg[cyan]%}"
YLW="%{$fg[yellow]%}"
RST="%{$reset_color%}"

HOME_ICON=$'\uf015'   # 

cytechnika_path() {
  local rel

  if [[ "$PWD" == "$HOME" ]]; then
    # pad right for WT glyph width
    print -r -- " ${HOME_ICON}  "
    return
  fi

  if [[ "$PWD" == "$HOME"/* ]]; then
    rel="${PWD#$HOME/}"
    print -r -- " ~/${rel} "
    return
  fi

  print -r -- " ${PWD} "
}

PROMPT="${RED_B}┌─[${GRN_B}%n${RST}${YLW_B}@${RST}${CYN}%m${RST}${RED_B}] - [${GRN_B}\$(cytechnika_path)${RED_B}] - [ ${YLW}%D{%H:%M:%S}${RED_B} ]${RST}
${RED_B}└─[${YLW_B}\$${RED_B}]>${RST} "