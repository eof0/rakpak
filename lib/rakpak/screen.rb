# frozen_string_literal: true

require_relative "text"
require_relative "theme"

module Rakpak
  class Screen
    attr_reader :w, :h

    def initialize(w, h)
      resize(w, h)
    end

    def resize(w, h)
      @w = [w, 20].max
      @h = [h, 6].max
      @ch = Array.new(@w * @h, " ")
      @st = Array.new(@w * @h, nil)
    end

    def clear(style = nil)
      @ch.fill(" ")
      @st.fill(style)
    end

    def put(x, y, text, style = nil)
      return x if y.negative? || y >= @h

      row = y * @w
      cx = x
      printable(text).each_grapheme_cluster do |g|
        cw = Text.gw(g)
        break if cx >= @w

        if cx >= 0 && cw.positive?
          clear_halves(row + cx)
          clear_halves(row + cx + 1) if cw == 2 && cx + 1 < @w
          @ch[row + cx] = g
          @st[row + cx] = style
          if cw == 2 && cx + 1 < @w
            @ch[row + cx + 1] = ""
            @st[row + cx + 1] = style
          end
        end
        cx += cw
      end
      cx
    end

    # A wide glyph owns two cells; overwriting either half must blank the other or the row wraps.
    def clear_halves(idx)
      col = idx % @w
      @ch[idx - 1] = " " if @ch[idx] == "" && col.positive? && Text.gw(@ch[idx - 1]) == 2
      @ch[idx + 1] = " " if col < @w - 1 && @ch[idx + 1] == "" && Text.gw(@ch[idx]) == 2
    end

    # One binary byte in @ch would break frame concatenation mid-render.
    def printable(text)
      str = text.to_s
      str = str.dup.force_encoding(Encoding::UTF_8) unless str.encoding == Encoding::UTF_8
      str.valid_encoding? ? str : str.scrub("·")
    end

    def fill(x, y, w, h, char = " ", style = nil)
      h.times do |dy|
        yy = y + dy
        next if yy.negative? || yy >= @h

        row = yy * @w
        w.times do |dx|
          xx = x + dx
          next if xx.negative? || xx >= @w

          clear_halves(row + xx)
          @ch[row + xx] = char
          @st[row + xx] = style
        end
      end
    end

    def hline(x, y, w, style = nil, char = "─")
      fill(x, y, w, 1, char, style)
    end

    def vline(x, y, h, style = nil, char = "│")
      fill(x, y, 1, h, char, style)
    end

    def box(x, y, w, h, style = nil, fill_style = nil)
      return if w < 2 || h < 2

      fill(x, y, w, h, " ", fill_style) if fill_style
      put(x, y, "╭#{'─' * (w - 2)}╮", style)
      put(x, y + h - 1, "╰#{'─' * (w - 2)}╯", style)
      (1...(h - 1)).each do |dy|
        put(x, y + dy, "│", style)
        put(x + w - 1, y + dy, "│", style)
      end
    end

    def veil(style = Theme::FAINT)
      @st.fill(style)
    end

    def render
      out = +"\e[H"
      cur = :none
      @h.times do |y|
        row = y * @w
        @w.times do |x|
          st = @st[row + x]
          if st != cur
            out << Theme::RESET
            out << st if st
            cur = st
          end
          out << @ch[row + x]
        end
        out << Theme::RESET
        cur = nil
        out << "\r\n" unless y == @h - 1
      end
      out << Theme::RESET
      out
    end
  end
end
