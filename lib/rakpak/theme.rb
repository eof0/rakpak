# frozen_string_literal: true

module Rakpak
  # Every style is emitted after a reset, so fragments needn't be self-contained.
  module Theme
    RESET     = "\e[0m"

    NORMAL    = "\e[38;5;252m"
    DIM       = "\e[38;5;243m"
    FAINT     = "\e[38;5;239m"
    BORDER    = "\e[38;5;238m"

    ACCENT    = "\e[38;5;39m"
    TITLE     = "\e[1;38;5;39m"
    DIR       = "\e[1;38;5;75m"
    EXEC      = "\e[38;5;114m"
    LINK      = "\e[38;5;141m"
    TAG       = "\e[38;5;215m"

    OK        = "\e[38;5;114m"
    WARN      = "\e[38;5;215m"
    ERR       = "\e[38;5;203m"

    SEL_BG    = "\e[48;5;236m"
    CUR_BG    = "\e[48;5;24m"
    HEAD      = "\e[48;5;236m\e[38;5;250m"
    MODAL_BG  = "\e[48;5;234m"

    KEY       = "\e[1;38;5;215m"
  end
end
