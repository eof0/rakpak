# frozen_string_literal: true

require_relative "theme"
require_relative "text"

module Rakpak
  class Modal
    attr_reader :result

    def initialize(title:, footer: "")
      @title = title
      @footer = footer
      @result = nil
    end

    def dims(screen)
      [[screen.w - 6, 72].min, [screen.h - 4, 20].min]
    end

    def draw(screen)
      w, h = dims(screen)
      w = [w, screen.w].min
      h = [h, screen.h].min
      x = (screen.w - w) / 2
      y = (screen.h - h) / 2
      screen.box(x, y, w, h, Theme::ACCENT, Theme::MODAL_BG)
      screen.put(x + 2, y, " #{@title} ", Theme::MODAL_BG + Theme::TITLE)
      ftext = footer_text
      if ftext && !ftext.empty?
        screen.put(x + 2, y + h - 1, " #{Text.fit(ftext, w - 6)} ",
                   Theme::MODAL_BG + footer_style)
      end
      body(screen, x + 2, y + 2, w - 4, h - 4)
    end

    def footer_text = @footer
    def footer_style = Theme::DIM

    def body(screen, x, y, w, h); end

    def handle(_key) = nil
  end

  class SelectModal < Modal
    Item = Struct.new(:label, :value, :blurb, :enabled, :why, keyword_init: true)

    def initialize(title:, items:, footer: "j/k move · enter choose · esc back", index: 0)
      super(title: title, footer: footer)
      @items = items
      @index = first_enabled(index)
    end

    def dims(screen)
      w = [[screen.w - 6, 76].min, 30].max
      h = [@items.size + 5, screen.h - 2].min
      [w, h]
    end

    def first_enabled(from)
      return from if @items[from]&.enabled

      idx = @items.index(&:enabled)
      idx || from
    end

    def body(screen, x, y, w, _h)
      @items.each_with_index do |item, i|
        row = y + i
        sel = i == @index
        style = if !item.enabled then Theme::MODAL_BG + Theme::FAINT
                elsif sel then Theme::CUR_BG + "\e[1;38;5;231m"
                else Theme::MODAL_BG + Theme::NORMAL
                end
        screen.fill(x - 1, row, w + 2, 1, " ", style)
        screen.put(x, row, sel ? "❯ " : "  ", style)
        cx = screen.put(x + 2, row, Text.fit(item.label, 22), style)
        note = item.enabled ? item.blurb.to_s : "(#{item.why})"
        nstyle = if !item.enabled then Theme::MODAL_BG + Theme::FAINT
                 elsif sel then Theme::CUR_BG + "\e[38;5;252m"
                 else Theme::MODAL_BG + Theme::DIM
                 end
        screen.put(x + 24, row, Text.fit(note, w - 25), nstyle) if w > 25 && cx <= x + 24
      end
    end

    def handle(key)
      case key
      when :up, "k" then move(-1)
      when :down, "j" then move(1)
      when :enter, "l", :right
        return nil unless @items[@index]&.enabled

        @result = @items[@index].value
        :done
      when :esc, "q", "h", :left then :cancel
      when /\A[1-9]\z/
        i = key.to_i - 1
        if @items[i]&.enabled
          @index = i
          @result = @items[i].value
          :done
        end
      end
    end

    def move(dir)
      n = @items.size
      i = @index
      n.times do
        i = (i + dir) % n
        next unless @items[i].enabled

        @index = i
        break
      end
      nil
    end
  end

  class FormModal < Modal
    Row = Struct.new(:kind, :label, :hint, :get, :set, :values, keyword_init: true)

    def initialize(title:, rows:, footer: "space toggle · h/l adjust · enter accept · esc back")
      super(title: title, footer: footer)
      @rows = rows
      @index = @rows.index { |r| r.kind != :spacer } || 0
      @top = 0
      @error = nil
    end

    def dims(screen)
      w = [[screen.w - 4, 78].min, 40].max
      h = [@rows.size + 5, screen.h - 2].min
      [w, h]
    end

    def body(screen, x, y, w, h)
      @top = @index - h + 1 if @index >= @top + h
      @top = @index if @index < @top
      @top = [@top, 0].max
      visible = @rows[@top, h] || []
      visible.each_with_index do |row, i|
        draw_row(screen, x, y + i, w, row, @top + i == @index)
      end
      return unless @rows.size > h

      screen.put(x + w - 4, y + h - 1, "#{@top + h}/#{@rows.size}", Theme::MODAL_BG + Theme::FAINT)
    end

    def draw_row(screen, x, y, w, row, sel)
      style = sel ? Theme::CUR_BG + "\e[38;5;231m" : Theme::MODAL_BG + Theme::NORMAL
      dim   = sel ? Theme::CUR_BG + "\e[38;5;250m" : Theme::MODAL_BG + Theme::DIM
      screen.fill(x - 1, y, w + 2, 1, " ", sel ? Theme::CUR_BG : Theme::MODAL_BG)
      return if row.kind == :spacer

      case row.kind
      when :toggle
        on = row.get.call
        screen.put(x, y, on ? " [×] " : " [ ] ", sel ? style : (on ? Theme::MODAL_BG + Theme::OK : Theme::MODAL_BG + Theme::DIM))
        screen.put(x + 5, y, Text.fit(row.label, 24), style)
        screen.put(x + 30, y, Text.fit(row.hint.to_s, w - 31), dim)
      when :choice
        screen.put(x + 1, y, Text.fit(row.label, 13), style)
        val = row.get.call
        entry = row.values.find { |v| v[1] == val }
        ok = entry.nil? || entry[2] != false
        disp = entry&.first || val.to_s
        vstyle = if !ok then (sel ? Theme::CUR_BG : Theme::MODAL_BG) + Theme::ERR
                 elsif sel then Theme::CUR_BG + Theme::KEY
                 else Theme::MODAL_BG + Theme::TAG
                 end
        screen.put(x + 15, y, "#{ok ? '‹' : '✗'} #{Text.fit(disp, 16)} #{ok ? '›' : ''}", vstyle)
        note = ok ? row.hint.to_s : (entry[3] || "unavailable here")
        screen.put(x + 36, y, Text.fit(note, w - 37),
                   ok ? dim : (sel ? Theme::CUR_BG : Theme::MODAL_BG) + Theme::ERR)
      when :number
        screen.put(x + 1, y, Text.fit(row.label, 13), style)
        val = row.get.call
        rng = row.values
        screen.put(x + 15, y, "‹ #{Text.pad(val.to_s, 3)}›", sel ? Theme::CUR_BG + Theme::KEY : Theme::MODAL_BG + Theme::TAG)
        bar_w = [[w - 38, 20].min, 8].max
        filled = rng.size <= 1 ? bar_w : ((val - rng.first).to_f / (rng.last - rng.first) * bar_w).round
        screen.put(x + 22, y, "█" * filled, sel ? Theme::CUR_BG + Theme::KEY : Theme::MODAL_BG + Theme::ACCENT)
        screen.put(x + 22 + filled, y, "░" * (bar_w - filled), dim)
        screen.put(x + 24 + bar_w, y, Text.fit("#{rng.first}–#{rng.last}  #{row.hint}", w - 25 - bar_w), dim)
      when :label
        screen.put(x + 1, y, Text.fit(row.label, w - 2), Theme::MODAL_BG + Theme::DIM)
      end
    end

    def handle(key)
      @error = nil
      case key
      when :up, "k" then move(-1)
      when :down, "j" then move(1)
      when :left, "h" then adjust(-1)
      when :right, "l" then adjust(1)
      when :space then toggle
      when :enter
        if (bad = unusable)
          @error = bad
          nil
        else
          @result = true
          :done
        end
      when :esc, "q" then :cancel
      end
    end

    def unusable
      @rows.each do |row|
        next unless row.kind == :choice

        entry = row.values.find { |v| v[1] == row.get.call }
        next if entry.nil? || entry[2] != false

        return "#{entry[0]}: #{entry[3] || 'not available here'}"
      end
      nil
    end

    def footer_text = @error || @footer
    def footer_style = @error ? Theme::ERR : Theme::DIM

    def move(dir)
      n = @rows.size
      i = @index
      n.times do
        i = (i + dir) % n
        next if %i[spacer label].include?(@rows[i].kind)

        @index = i
        break
      end
      nil
    end

    def toggle
      row = @rows[@index]
      return nil unless row&.kind == :toggle

      row.set.call(!row.get.call)
      nil
    end

    def adjust(dir)
      row = @rows[@index]
      return nil unless row

      case row.kind
      when :toggle then row.set.call(!row.get.call)
      when :number
        rng = row.values
        row.set.call((row.get.call + dir).clamp(rng.first, rng.last))
      when :choice
        vals = row.values
        cur = vals.index { |v| v[1] == row.get.call } || 0
        row.set.call(vals[(cur + dir) % vals.size][1])
      end
      nil
    end
  end

  class InputModal < Modal
    def initialize(title:, value: "", hint: "", footer: "enter accept · esc back", validate: nil)
      super(title: title, footer: footer)
      @buf = value.dup
      @cur = @buf.length
      @hint = hint
      @validate = validate
      @error = nil
    end

    def footer_text = @error || @footer
    def footer_style = @error ? Theme::ERR : Theme::DIM
    def text = @buf.strip

    def dims(screen)
      [[[screen.w - 6, 74].min, 40].max, @hint.empty? ? 7 : 8]
    end

    def body(screen, x, y, w, _h)
      screen.put(x, y, Text.fit(@hint, w), Theme::MODAL_BG + Theme::DIM) unless @hint.empty?
      field(screen, x, y + (@hint.empty? ? 0 : 2), w, active: true)
    end

    def field(screen, x, row, w, active: true)
      screen.fill(x, row, w, 1, " ", Theme::SEL_BG)
      width = w - 2
      # Scroll by display columns, not characters.
      off = 0
      off += 1 while off < @cur && Text.width(@buf[off...@cur]) >= width
      shown = +""
      @buf[off..].to_s.each_grapheme_cluster do |g|
        break if Text.width(shown) + Text.gw(g) > width

        shown << g
      end
      screen.put(x + 1, row, shown, Theme::SEL_BG + (active ? "\e[38;5;231m" : Theme::DIM))
      return unless active

      cx = x + 1 + Text.width(@buf[off...@cur].to_s)
      ch = @buf[@cur] || " "
      screen.put(cx, row, ch, "\e[7m\e[38;5;39m")
    end

    def handle(key)
      @error = nil
      case key
      when :enter
        text = @buf.strip
        return nil if text.empty?

        if (bad = @validate&.call(text))
          @error = bad
          return nil
        end
        @result = text
        return :done
      when :esc then return :cancel
      when :backspace
        if @cur.positive?
          @buf.slice!(@cur - 1)
          @cur -= 1
        end
      when :delete then @buf.slice!(@cur) if @cur < @buf.length
      when :left  then @cur = [@cur - 1, 0].max
      when :right then @cur = [@cur + 1, @buf.length].min
      when :home, :ctrl_a then @cur = 0
      when :end, :ctrl_e then @cur = @buf.length
      when :ctrl_u then @buf.slice!(0, @cur) && (@cur = 0)
      when :ctrl_k then @buf.slice!(@cur..)
      when :ctrl_w
        left = @buf[0, @cur].sub(/\S*\s*\z/, "")
        @buf = left + (@buf[@cur..] || "")
        @cur = left.length
      when :space then insert(" ")
      when String then insert(key)
      end
      nil
    end

    def insert(str)
      return unless str.match?(/\A[[:print:]]\z/)

      @buf.insert(@cur, str)
      @cur += str.length
    end
  end

  class WhereModal < Modal
    attr_reader :index

    def initialize(here:, home:, index: 0, text: "", validate: nil, title: "save it where?")
      super(title: title, footer: "1-3 or ↑↓ pick · enter choose · esc back")
      @choices = [["This directory", here], ["Home directory", home], ["Specify", nil]]
      @index = index
      @field = InputModal.new(title: "", value: text, validate: validate)
    end

    def text = @field.text

    def dims(screen)
      [[[screen.w - 6, 84].min, 44].max, 10]
    end

    def body(screen, x, y, w, _h)
      @choices.each_with_index do |(label, path), i|
        row = y + i
        sel = i == @index
        bg = sel ? Theme::CUR_BG : Theme::MODAL_BG
        screen.fill(x - 1, row, w + 2, 1, " ", bg)
        screen.put(x, row, "#{i + 1}. #{label}", bg + (sel ? "\e[1;38;5;231m" : Theme::NORMAL))
        next unless path

        screen.put(x + 20, row, Text.fit_left(path, w - 21), bg + (sel ? "\e[38;5;252m" : Theme::DIM))
      end
      @field.field(screen, x + 3, y + 4, w - 3, active: @index == 2)
    end

    def footer_text = @error || @footer
    def footer_style = @error ? Theme::ERR : Theme::DIM

    def handle(key)
      @error = nil
      case key
      when :esc then return :cancel
      when :enter then return choose
      when :up then @index = (@index - 1) % 3
      when :down, :tab then @index = (@index + 1) % 3
      else
        return field_key(key) if @index == 2

        case key
        when "k" then @index = (@index - 1) % 3
        when "j" then @index = (@index + 1) % 3
        when "1", "2"
          @index = key.to_i - 1
          return choose
        when "3" then @index = 2
        else field_key(key)
        end
      end
      nil
    end

    def field_key(key)
      @index = 2
      @field.handle(key)
      nil
    end

    def choose
      if @index < 2
        @result = @choices[@index][1]
        return :done
      end
      if text.empty?
        @error = "type a folder, or pick 1 or 2"
        return nil
      end
      res = @field.handle(:enter)
      if res == :done
        @result = @field.result
        return :done
      end
      @error = @field.footer_text
      nil
    end
  end

  # Only enter runs it: a single letter (b reads as "back") is too easy to hit by mistake.
  class ConfirmModal < Modal
    def initialize(title:, lines:, warnings: [], errors: [], footer: nil)
      super(title: title,
            footer: footer || (errors.empty? ? "enter run · esc back" : "esc back"))
      @lines = lines
      @warnings = warnings
      @errors = errors
    end

    def dims(screen)
      w = [screen.w - 4, 92].min
      h = 6 + laid_out(w - 4).size + @warnings.size + @errors.size
      [w, [h, screen.h - 2].min]
    end

    # Wrap, don't clip: the user must see exactly what will run.
    def laid_out(w)
      @lines.flat_map do |style, text|
        if style == :cmd
          Text.wrap(text, w, 5).map { |l| [style, l] }
        else
          [[style, Text.fit(text, w)]]
        end
      end
    end

    def body(screen, x, y, w, h)
      row = y
      laid_out(w).each do |style, text|
        break if row >= y + h

        st = case style
             when :cmd then Theme::MODAL_BG + Theme::NORMAL
             when :key then Theme::MODAL_BG + Theme::DIM
             when :head then Theme::MODAL_BG + Theme::TITLE
             else Theme::MODAL_BG + Theme::NORMAL
             end
        screen.put(x, row, text, st)
        row += 1
      end
      @warnings.each do |msg|
        break if row >= y + h

        screen.put(x, row, Text.fit("!  #{msg}", w), Theme::MODAL_BG + Theme::WARN)
        row += 1
      end
      @errors.each do |msg|
        break if row >= y + h

        screen.put(x, row, Text.fit("✗  #{msg}", w), Theme::MODAL_BG + Theme::ERR)
        row += 1
      end
    end

    def handle(key)
      return :cancel if key == :esc || key == "q"

      return nil unless @errors.empty?

      return nil unless key == :enter

      @result = :run
      :done
    end
  end

  class MessageModal < Modal
    def initialize(title:, lines:, style: Theme::ERR)
      super(title: title, footer: "any key to dismiss")
      @lines = Array(lines)
      @style = style
      @top = 0
      @rows = 0
    end

    def dims(screen)
      h = [@lines.size + 5, screen.h - 2].min
      @rows = h - 4 # dims runs before body, and footer_text needs this
      [[[screen.w - 6, 70].min, 30].max, h]
    end

    def body(screen, x, y, w, h)
      @rows = h
      @top = @top.clamp(0, [@lines.size - h, 0].max)
      @lines[@top, h].to_a.each_with_index do |l, i|
        screen.put(x, y + i, Text.fit(l, w), Theme::MODAL_BG + @style)
      end
    end

    def footer_text
      return @footer unless scrollable?

      "#{@top + @rows}/#{@lines.size} · j k scroll · any other key dismisses"
    end

    def scrollable? = @lines.size > @rows

    def handle(key)
      return :cancel unless scrollable?

      case key
      when :down, "j" then (@top += 1) && nil
      when :up, "k" then (@top -= 1) && nil
      when :pgdn, :ctrl_d then (@top += @rows / 2) && nil
      when :pgup, :ctrl_u then (@top -= @rows / 2) && nil
      else :cancel
      end
    end
  end
end
