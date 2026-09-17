# frozen_string_literal: true

require "set"
require_relative "dir_cache"
require_relative "theme"
require_relative "text"

module Rakpak
  class Browser
    attr_reader :cwd, :tags, :filter

    def initialize(start_dir = Dir.pwd, sizer: nil)
      @dirs = DirCache.new
      @sizer = sizer
      @tags = Set.new
      @cursor = {}
      @show_hidden = false
      @filter = nil
      @filtering = false
      @show_queue = true
      @pending = nil
      @preview_cache = {}
      @cwd = resolve(start_dir)
    end

    def resolve(dir)
      d = File.expand_path(dir)
      d = File.dirname(d) until File.directory?(d) || d == "/"
      d
    end

    def entries
      list = @dirs.list(@cwd, hidden: @show_hidden) || []
      return list unless @filter && !@filter.empty?

      needle = @filter.downcase
      list.select { |e| e.fold.include?(needle) }
    end

    def index
      @cursor[@cwd] = (@cursor[@cwd] || 0).clamp(0, [entries.size - 1, 0].max)
    end

    def index=(i)
      @cursor[@cwd] = i.clamp(0, [entries.size - 1, 0].max)
    end

    def current = entries[index]
    def show_hidden? = @show_hidden
    def show_queue? = @show_queue
    def filtering? = @filtering

    def tag(path)
      path = File.expand_path(path)
      return unless @tags.add?(path)

      # A figure may linger from a cursor-only pack of this path; don't trust it.
      @sizer&.forget(path)
      @sizer&.request(path)
    end

    # All tag removals must pass here so the sizer drops its now-stale figure.
    def untag(path)
      return unless @tags.delete?(path)

      @sizer&.forget(path)
    end

    def toggle_tag(entry = current)
      return unless entry

      @tags.include?(entry.path) ? untag(entry.path) : tag(entry.path)
    end

    def tag_all = entries.each { |e| tag(e.path) }
    def untag_all_here = entries.each { |e| untag(e.path) }
    def clear_tags = @tags.to_a.each { |p| untag(p) }

    def replace_tags(list)
      (@tags.to_a - list).each { |p| untag(p) }
      list.each { |p| tag(p) }
    end

    def selection
      return @tags.to_a.sort if @tags.any?

      current ? [current.path] : []
    end

    def refresh!
      @dirs.invalidate!
      @preview_cache.clear
      return unless @sizer

      @sizer.invalidate!
      @tags.each { |p| @sizer.request(p) }
    end

    def move(delta)
      self.index = index + delta
    end

    def step(delta)
      n = entries.size
      return if n.zero?

      self.index = (index + delta) % n
    end

    def descend
      e = current
      return unless e&.dir?
      return unless File.readable?(e.path)

      @cwd = e.path
      @cursor[@cwd] ||= 0
      @filter = nil
    end

    def ascend
      return if @cwd == "/"

      child = @cwd
      @cwd = File.dirname(@cwd)
      @filter = nil
      idx = (@dirs.list(@cwd, hidden: @show_hidden) || []).index { |e| e.path == child }
      @cursor[@cwd] = idx if idx
    end

    def goto(dir)
      d = File.expand_path(dir)
      return false unless File.directory?(d) && File.readable?(d)

      @cwd = d
      @filter = nil
      true
    end

    def jump_to(path)
      path = File.expand_path(path)
      return false unless goto(File.dirname(path))

      @show_hidden = true if File.basename(path).start_with?(".")
      idx = entries.index { |e| e.path == path }
      self.index = idx if idx
      !idx.nil?
    end

    def handle(key)
      return handle_filter(key) if @filtering

      if @pending == "g"
        @pending = nil
        case key
        when "g" then return (self.index = 0) && nil
        when "h" then return goto(Dir.home) && nil
        when "r" then return goto("/") && nil
        end
        # Not a chord: handle it as its own key so a stray g never swallows q, p or space.
      end

      result = case key
      when "j", :down  then step(1)
      when "k", :up    then step(-1)
      when "h", :left  then ascend
      when "l", :right, :enter then descend
      when :ctrl_d then move(page / 2)
      when :ctrl_u then move(-page / 2)
      when :pgdn then move(page)
      when :pgup then move(-page)
      when "G" then self.index = entries.size - 1
      when "g" then @pending = "g"
      when :space
        toggle_tag
        move(1)
      when "a" then tag_all
      when "d" then untag_all_here
      when "D" then clear_tags
      when "." then toggle_hidden
      when "t" then toggle_queue
      when "/" then start_filter
      when :ctrl_r then refresh!
      when "~" then goto(Dir.home)
      when "p" then :archive
      when "u" then :unpack
      when "T" then :tags
      when "?" then :help
      when "b" then :jobs
      when "q", :ctrl_c then :quit
      end
      %i[archive unpack tags help jobs quit].include?(result) ? result : nil
    end

    def toggle_hidden
      @show_hidden = !@show_hidden
      nil
    end

    def toggle_queue
      @show_queue = !@show_queue
      nil
    end

    def start_filter
      @filtering = true
      @filter = +""
      nil
    end

    def handle_filter(key)
      case key
      when :enter then @filtering = false
      when :esc
        @filtering = false
        @filter = nil
      when :backspace then @filter = @filter.to_s[0..-2] || ""
      when :space then @filter = "#{@filter} "
      when String then @filter = "#{@filter}#{key}" if key.match?(/\A[[:print:]]\z/)
      end
      self.index = index
      nil
    end

    def page = @page_size || 10

    def draw(screen, status_line)
      @page_size = screen.h - 5
      draw_header(screen)
      body_y = 1
      body_h = screen.h - 3
      layout(screen.w).each { |pane| draw_pane(screen, pane, body_y, body_h) }
      draw_status(screen, screen.h - 2)
      draw_footer(screen, screen.h - 1, status_line)
    end

    def layout(w)
      panes = []
      x = 0
      if @show_queue && w >= 60
        qw = (w * 0.3).to_i.clamp(24, 60)
        panes << { kind: :queue, x: 0, w: qw }
        x = qw + 1
      end
      rest = w - x
      pw, prw =
        if rest >= 100    then [24, ((rest - 24) * 0.42).to_i]
        elsif rest >= 76  then [18, ((rest - 18) * 0.40).to_i]
        elsif rest >= 54  then [0, (rest * 0.38).to_i]
        else [0, 0]
        end
      if pw.positive?
        panes << { kind: :parent, x: x, w: pw }
        x += pw + 1
      end
      cw = w - x - (prw.positive? ? prw + 1 : 0)
      panes << { kind: :current, x: x, w: cw }
      x += cw + 1
      panes << { kind: :preview, x: x, w: prw } if prw.positive?
      panes
    end

    def draw_header(screen)
      screen.fill(0, 0, screen.w, 1, " ", Theme::HEAD)
      screen.put(1, 0, "rakpak", Theme::HEAD + "\e[1;38;5;39m")
      right = tag_summary
      avail = screen.w - 10 - Text.width(right) - 3
      screen.put(9, 0, Text.fit_left(Text.tilde(@cwd), [avail, 1].max), Theme::HEAD + "\e[38;5;231m")
      screen.put(screen.w - Text.width(right) - 1, 0, right,
                 @tags.empty? ? Theme::HEAD : Theme::HEAD + Theme::TAG)
    end

    def tag_summary
      return "nothing tagged" if @tags.empty?

      t = @sizer&.total(@tags.to_a)
      count = "#{@tags.size} tagged"
      return count unless t

      size = t.bytes.zero? && t.partial ? "…" : "#{t.partial ? '≥' : ''}#{Text.bytes(t.bytes)}"
      "#{count} · #{size}"
    end

    def draw_pane(screen, pane, y, h)
      screen.vline(pane[:x] - 1, y, h, Theme::BORDER) if pane[:x].positive?
      case pane[:kind]
      when :queue   then draw_queue(screen, pane, y, h)
      when :parent  then draw_parent(screen, pane, y, h)
      when :current then draw_list(screen, pane, y, h, entries, index, true)
      when :preview then draw_preview(screen, pane, y, h)
      end
    end

    def draw_queue(screen, pane, y, h)
      x = pane[:x]
      w = pane[:w]
      screen.put(x + 1, y, Text.fit("QUEUE · #{tag_summary}", w - 2), Theme::TITLE)
      list = @tags.to_a.sort
      return if list.empty? || h < 2

      rows = h - 1
      shown = list.size > rows ? list.first(rows - 1) : list
      names = shown.map { |p| File.basename(p) }
      name_w = [names.map { |n| Text.width(n) }.max || 0, w / 3].min
      shown.each_with_index do |path, i|
        row = y + 1 + i
        res = @sizer&.[](path)
        meta = res ? "#{res.partial ? '≥' : ''}#{Text.bytes(res.bytes)}" : "…"
        here = current&.path == path
        bg = here ? Theme::SEL_BG : ""
        screen.fill(x, row, w, 1, " ", Theme::SEL_BG) if here
        screen.put(x, row, " ▌", bg + Theme::TAG)
        nx = screen.put(x + 2, row, Text.pad(Text.fit(names[i], name_w), name_w), bg + (File.directory?(path) ? Theme::DIR : Theme::NORMAL))
        avail = w - (nx - x) - Text.width(meta) - 4
        screen.put(nx + 2, row, Text.fit_left(Text.tilde(File.dirname(path)), avail), bg + Theme::DIM) if avail > 3
        screen.put(x + w - Text.width(meta) - 1, row, meta, bg + Theme::DIM)
      end
      return unless list.size > shown.size

      screen.put(x + 1, y + h - 1, "… #{list.size - shown.size} more", Theme::FAINT)
    end

    def draw_parent(screen, pane, y, h)
      return if @cwd == "/"

      list = @dirs.list(File.dirname(@cwd), hidden: @show_hidden) || []
      idx = list.index { |e| e.path == @cwd } || 0
      draw_list(screen, pane, y, h, list, idx, false)
    end

    def draw_list(screen, pane, y, h, list, cur, active)
      x = pane[:x]
      w = pane[:w]
      if list.nil? || list.empty?
        msg = @filter && !@filter.to_s.empty? ? "no match" : "empty"
        screen.put(x + 1, y, msg, Theme::FAINT)
        return
      end

      top = [[cur - (h / 2), list.size - h].min, 0].max
      list[top, h].to_a.each_with_index do |e, i|
        row = y + i
        sel = (top + i) == cur
        tagged = @tags.include?(e.path)
        bg = if sel && active then Theme::CUR_BG
             elsif sel then Theme::SEL_BG
             end
        screen.fill(x, row, w, 1, " ", bg) if bg
        mark_style = tagged ? (bg.to_s + Theme::TAG) : (bg.to_s + Theme::FAINT)
        screen.put(x, row, tagged ? " ▌" : "  ", mark_style)
        name_style = bg ? bg + (sel && active ? "\e[1;38;5;231m" : e.style) : e.style
        avail = w - 3
        avail -= 5 unless pane[:kind] == :parent
        screen.put(x + 2, row, Text.fit(e.display, [avail, 1].max), name_style)
        next if pane[:kind] == :parent || w < 22

        meta = e.dir? ? "" : Text.bytes(e.size)
        screen.put(x + w - Text.width(meta) - 1, row, meta,
                   bg ? bg + Theme::DIM : Theme::DIM)
      end

      return unless list.size > h

      pos = (top.to_f / (list.size - h) * (h - 1)).round
      screen.put(x + w - 1, y + pos, "▐", Theme::ACCENT)
    end

    def draw_preview(screen, pane, y, h)
      e = current
      x = pane[:x]
      w = pane[:w]
      unless e
        screen.put(x + 1, y, "nothing to preview", Theme::FAINT)
        return
      end

      preview_lines(e, w - 2, h).each_with_index do |(txt, st), i|
        screen.put(x + 1, y + i, Text.fit(txt, w - 2), st)
      end
    end

    def preview_lines(entry, w, h)
      key = [entry.path, entry.mtime, w, h]
      @preview_cache.delete(@preview_cache.keys.first) if @preview_cache.size > 40
      @preview_cache[key] ||= build_preview(entry, w, h)
    end

    def build_preview(entry, w, h)
      return [["permission denied", Theme::ERR]] unless entry.readable?

      if entry.dir?
        kids = @dirs.list(entry.path, hidden: @show_hidden)
        return [["permission denied", Theme::ERR]] if kids.nil?
        return [["empty folder", Theme::FAINT]] if kids.empty?

        head = kids.first(h - 1).map { |k| [" #{k.display}", k.style] }
        head << ["  … #{kids.size - head.size} more", Theme::FAINT] if kids.size > head.size
        head
      else
        file_preview(entry, w, h)
      end
    end

    def file_preview(entry, w, h)
      # Reading a FIFO or device blocks and would freeze the UI.
      kind = entry.target_stat
      return [["not a regular file", Theme::FAINT]] unless kind&.file?

      size = entry.size.to_i
      head = File.binread(entry.path, 8192) || ""
      if head.empty?
        return [["empty file", Theme::FAINT]]
      end

      if binary?(head)
        [["binary · #{Text.bytes(size)}", Theme::TAG], ["", nil]] +
          hexdump(head, h - 3, w)
      else
        head.force_encoding("UTF-8").scrub("·").lines.first(h).map { |l| [l.chomp.tr("\t", "  "), Theme::NORMAL] }
      end
    rescue StandardError => e
      [[e.class.name.split("::").last, Theme::ERR]]
    end

    def hexdump(bytes, rows, width)
      return [] if rows <= 0

      per = ((width - 2) / 4).clamp(4, 16)
      hex_w = (per * 3) - 1
      bytes.bytes.each_slice(per).first([rows, 0].max).map do |slice|
        hex = slice.map { |b| format("%02x", b) }.join(" ")
        asc = slice.map { |b| b.between?(32, 126) ? b.chr : "." }.join
        ["#{hex.ljust(hex_w)}  #{asc}", Theme::DIM]
      end
    end

    def binary?(sample)
      return false if sample.empty?

      sample.byteslice(0, 1024).bytes.any? { |b| b < 9 }
    end

    def draw_status(screen, y)
      screen.fill(0, y, screen.w, 1, " ", Theme::SEL_BG)
      e = current
      if @filtering || (@filter && !@filter.empty?)
        screen.put(1, y, "/#{@filter}", Theme::SEL_BG + Theme::KEY)
        screen.put(2 + Text.width(@filter.to_s), y, @filtering ? "▏" : "", Theme::SEL_BG + Theme::ACCENT)
        return
      end
      return unless e

      st = e.stat
      left = if st
               mode = format("%04o", st.mode & 0o7777)
               time = st.mtime.strftime("%Y-%m-%d %H:%M")
               kind = e.symlink? ? "→ #{e.link_target}" : (e.dir? ? "dir" : Text.bytes(e.size))
               " #{mode}  #{time}  #{kind}"
             else
               " unreadable"
             end
      screen.put(0, y, Text.fit(left, screen.w - 14), Theme::SEL_BG + Theme::DIM)
      pos = " #{index + 1}/#{entries.size} "
      screen.put(screen.w - Text.width(pos), y, pos, Theme::SEL_BG + Theme::DIM)
    end

    HINTS = [["space", "tag"], ["←→", "nav"], ["a", "all"], ["t", "queue"], ["/", "find"],
             [".", "hidden"], ["p", "pack"], ["u", "unpack"], ["?", "help"]].freeze

    def draw_footer(screen, y, status_line)
      screen.fill(0, y, screen.w, 1, " ", nil)
      if status_line
        screen.put(1, y, Text.fit(status_line[0], screen.w - 2), status_line[1])
        return
      end
      x = 1
      HINTS.each do |k, label|
        break if x + Text.width(k) + Text.width(label) + 3 > screen.w

        x = screen.put(x, y, k, Theme::KEY)
        x = screen.put(x + 1, y, label, Theme::DIM)
        x += 2
      end
    end
  end
end
