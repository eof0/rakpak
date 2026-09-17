# frozen_string_literal: true

require_relative "term"
require_relative "screen"
require_relative "browser"
require_relative "modal"
require_relative "formats"
require_relative "plan"
require_relative "unpack"
require_relative "job"
require_relative "sizer"

module Rakpak
  class TagsModal < Modal
    def initialize(tags:, sizer:)
      super(title: "tagged", footer: "space/d remove · D clear all · esc back")
      @tags = tags
      @sizer = sizer
      @index = 0
    end

    def dims(screen)
      [[screen.w - 4, 96].min, [@tags.size + 5, screen.h - 2].min]
    end

    def body(screen, x, y, w, h)
      if @tags.empty?
        screen.put(x, y, "nothing tagged", Theme::MODAL_BG + Theme::FAINT)
        return
      end
      @index = @index.clamp(0, @tags.size - 1)
      top = [[@index - h + 1, @tags.size - h].min, 0].max
      @tags[top, h].to_a.each_with_index do |path, i|
        row = y + i
        sel = (top + i) == @index
        bg = sel ? Theme::CUR_BG : Theme::MODAL_BG
        screen.fill(x - 1, row, w + 2, 1, " ", bg)
        res = @sizer&.[](path)
        meta = res ? "#{res.partial ? '≥' : ''}#{Text.bytes(res.bytes)}" : "…"
        screen.put(x, row, sel ? "❯ " : "  ", bg + Theme::TAG)
        screen.put(x + 2, row, Text.fit_left(Text.tilde(path), w - Text.width(meta) - 5),
                   bg + (sel ? "\e[1;38;5;231m" : Theme::NORMAL))
        screen.put(x + w - Text.width(meta) - 1, row, meta, bg + Theme::DIM)
      end
    end

    def handle(key)
      case key
      when :up, "k" then @index -= 1
      when :down, "j" then @index += 1
      when :space, "d", :delete
        @tags.delete_at(@index) if @tags.any?
        @index = @index.clamp(0, [@tags.size - 1, 0].max)
      when "D" then @tags.clear
      when :esc, "q", :enter then return :cancel
      end
      @index = @index.clamp(0, [@tags.size - 1, 0].max)
      nil
    end
  end

  class App
    SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    WIZARD = %i[target options where output confirm].freeze
    UNPACK = %i[dest_where dest_name unpack_confirm].freeze

    def initialize(start_dir = Dir.home, pack: [])
      @sizer = Sizer.new
      @browser = Browser.new(start_dir, sizer: @sizer)
      w, h = Term.size
      @screen = Screen.new(w, h)
      @modal = nil
      @mode = :browse
      @jobs = []
      @reported_jobs = {}.compare_by_identity
      @focus_job = nil
      @quit_confirm = false
      @tags_ref = nil
      @notice = nil
      @notice_until = nil
      @plan = nil
      @wizard = WIZARD
      @wizard_pos = nil
      @quit = false
      return if pack.empty?

      pack.each { |p| @browser.tag(p) }
      @browser.jump_to(pack.first)
      start_wizard
    end

    def run
      Term.start
      loop do
        sync_size
        draw
        key = Term.wait_key(tick)
        reap_jobs
        next if key.nil?

        dispatch(key)
        break if @quit
      end
    ensure
      stop_jobs
      Term.stop
      report
    end

    private

    # Give jobs a moment to remove half-written archives before the terminal is restored.
    def stop_jobs
      running = @jobs.select(&:running?)
      return if running.empty?

      running.each(&:cancel)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      running.each { |j| j.wait([deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max) }
    end

    def tick
      return 0.08 if @jobs.any?(&:running?)
      return 0.4 if @browser.tags.any? { |t| @sizer[t].nil? }

      1.0
    end

    def sync_size
      return unless Term.resized

      Term.resized = false
      w, h = Term.size
      @screen.resize(w, h)
    end

    def notify(text, style = Theme::OK, secs = 4)
      @notice = [text, style]
      @notice_until = Process.clock_gettime(Process::CLOCK_MONOTONIC) + secs
    end

    def status_line
      if @notice && @notice_until && Process.clock_gettime(Process::CLOCK_MONOTONIC) < @notice_until
        return @notice
      end

      @notice = nil
      active = @jobs.select(&:running?)
      return nil if active.empty?

      j = active.first
      frame = SPINNER[(Process.clock_gettime(Process::CLOCK_MONOTONIC) * 12).to_i % SPINNER.size]
      more = active.size > 1 ? " (+#{active.size - 1} more)" : ""
      ["#{frame} #{j.label} #{File.basename(j.plan.outputs.first)} · #{j.file_count} files · " \
       "#{Text.bytes(j.output_size)} · #{Text.duration(j.elapsed)}#{more}   [b] jobs", Theme::ACCENT]
    end

    MIN_W = 40
    MIN_H = 10

    def draw
      @screen.clear
      if too_small?
        draw_too_small
        Term.flush_frame(@screen.render)
        return
      end
      if @mode == :job && @focus_job
        draw_job(@focus_job)
      else
        @browser.draw(@screen, status_line)
      end
      if @modal
        @screen.veil
        @modal.draw(@screen)
      end
      Term.flush_frame(@screen.render)
    end

    def too_small?
      w, h = Term.size
      w < MIN_W || h < MIN_H
    end

    def draw_too_small
      w, h = Term.size
      msg = "terminal too small"
      want = "need #{MIN_W}x#{MIN_H}, have #{w}x#{h}"
      @screen.put([(@screen.w - Text.width(msg)) / 2, 0].max, @screen.h / 2, msg, Theme::WARN)
      @screen.put([(@screen.w - Text.width(want)) / 2, 0].max, (@screen.h / 2) + 1, want, Theme::DIM)
    end

    def job_title(job, state)
      case state
      when :running then job.plan.gerund
      when :done then "finished"
      when :failed then "failed"
      when :cancelled then "cancelled"
      else "queued"
      end
    end

    def draw_job(job)
      s = @screen
      s.fill(0, 0, s.w, 1, " ", Theme::HEAD)
      s.put(1, 0, "rakpak", Theme::HEAD + "\e[1;38;5;39m")
      s.put(9, 0, job_title(job, job.state), Theme::HEAD + "\e[38;5;231m")
      s.put(s.w - 20, 0, Text.duration(job.elapsed), Theme::HEAD + Theme::DIM)

      y = 2
      job.plan.outputs.each do |out|
        size = begin
          File.directory?(out) ? nil : File.size(out)
        rescue StandardError
          nil
        end
        s.put(2, y, "→ ", Theme::DIM)
        s.put(4, y, Text.fit_left(out, s.w - 20), Theme::NORMAL)
        s.put(s.w - 12, y, Text.pad(Text.bytes(size), 10), Theme::TAG)
        y += 1
      end

      y += 1
      bar_w = s.w - 8
      frac = job.fraction
      if job.running?
        spin = SPINNER[(Process.clock_gettime(Process::CLOCK_MONOTONIC) * 12).to_i % SPINNER.size]
        s.put(2, y, spin, Theme::ACCENT)
      else
        s.put(2, y, job.ok? ? "✓" : "✗", job.ok? ? Theme::OK : Theme::ERR)
      end
      if frac
        filled = (frac * bar_w).round.clamp(0, bar_w)
        bar_style = if job.running? then Theme::ACCENT
                    elsif job.ok? then Theme::OK
                    else Theme::ERR
                    end
        s.put(4, y, "█" * filled, bar_style)
        s.put(4 + filled, y, "░" * (bar_w - filled), Theme::FAINT)
        seen = [job.file_count, job.total_files].min
        s.put(4, y + 1, "#{(frac * 100).round}%  #{seen}/#{job.total_files} entries",
              Theme::DIM)
      else
        s.put(4, y, "#{job.file_count} files", Theme::DIM)
      end
      y += 3

      s.put(2, y, Text.fit(job.current_file.to_s, s.w - 4), Theme::DIM)
      y += 2

      s.hline(0, y, s.w, Theme::BORDER)
      y += 1
      rows = [s.h - y - 1, 0].max
      job.tail(rows).each_with_index do |line, i|
        style = if line.start_with?("▸") then Theme::ACCENT
                elsif line.match?(/error|cannot|denied|warning/i) then Theme::WARN
                else Theme::FAINT
                end
        s.put(1, y + i, Text.fit(line, s.w - 2), style)
      end

      foot = if job.running?
               [["b", "background"], ["x", "cancel"], ["q", "quit"]]
             else
               [["esc", "back"], ["q", "quit"]]
             end
      s.fill(0, s.h - 1, s.w, 1, " ", nil)
      if job.done? && job.error
        s.put(1, s.h - 1, Text.fit(job.error, s.w - 2), Theme::ERR)
      else
        x = 1
        foot.each do |k, label|
          x = s.put(x, s.h - 1, k, Theme::KEY)
          x = s.put(x + 1, s.h - 1, label, Theme::DIM)
          x += 2
        end
      end
    end

    def dispatch(key)
      return modal_key(key) if @modal
      return job_key(key) if @mode == :job

      case @browser.handle(key)
      when :quit then request_quit
      when :archive then start_wizard
      when :unpack then start_unpack
      when :tags then open_tags
      when :help then open_help
      when :jobs then open_jobs
      end
    end

    def job_key(key)
      job = @focus_job
      case key
      when "b", :esc, :backspace
        @mode = :browse
        notify("running in the background · press b to watch", Theme::ACCENT) if job.running?
      when "x"
        if job.running?
          job.cancel
          notify("cancelling…", Theme::WARN)
        end
      when :enter
        @mode = :browse unless job.running?
      when "q" then request_quit
      end
    end

    def modal_key(key)
      # Raw mode delivers ctrl-c as a keystroke.
      res = key == :ctrl_c ? :cancel : @modal.handle(key)
      return if res.nil?

      modal = @modal
      @modal = nil

      if modal.is_a?(TagsModal)
        @browser.replace_tags(@tags_ref)
        @tags_ref = nil
        return
      end

      if @quit_confirm
        @quit_confirm = false
        @quit = true if res == :done
        return
      end

      return unless @wizard_pos

      res == :done ? wizard_forward(modal) : wizard_back
    end

    def start_wizard
      sel = @browser.selection
      if sel.empty?
        @modal = MessageModal.new(title: "nothing to archive",
                                  lines: ["Tag files or folders with space,",
                                          "or put the cursor on one and press p."],
                                  style: Theme::WARN)
        return
      end
      sel.each { |p| @sizer.request(p) }
      @plan = Plan.new(paths: sel, outdir: @browser.cwd)
      @name_edited = false
      @where = 0
      @where_text = ""
      @wizard = WIZARD
      @wizard_pos = 0
      open_wizard_step
    end

    def start_unpack
      e = @browser.current
      unless e && File.file?(e.path) && Unpack.archive?(e.path)
        @modal = MessageModal.new(
          title: "not an archive",
          lines: ["rakpak unpacks tarballs, zips and single",
                  "compressed files: .tar, .tar.gz, .tar.zst,",
                  ".tar.xz, .tar.bz2, .tar.lz4, .tar.br, .zip,",
                  "and .gz, .zst, .xz, .bz2, .lz4, .br on their own."],
          style: Theme::WARN
        )
        return
      end
      @plan = Unpack.new(archive: e.path, dest: @browser.cwd)
      @dest_parent = @browser.cwd
      @dest_name = Unpack.default_subdir(e.path) || "."
      @where = 0
      @where_text = ""
      @wizard = UNPACK
      @wizard_pos = 0
      open_wizard_step
    end

    def default_basename(sel)
      name = if sel.size > 1 then File.basename(@browser.cwd)
             elsif File.directory?(sel.first) || @plan&.single_compress? then File.basename(sel.first)
             else File.basename(sel.first).sub(/(?<=.)\.[^.]+\z/, "")
             end
      name.empty? || name == "/" ? "archive" : name
    end

    def open_wizard_step
      loop do
        step = @wizard[@wizard_pos]
        return finish_wizard if step.nil?

        modal = build_step(step)
        if modal.nil?
          @wizard_pos += 1
          next
        end
        @modal = modal
        return
      end
    end

    def wizard_forward(modal)
      apply_step(@wizard[@wizard_pos], modal)
      return if @wizard_pos.nil? # a step may have ended the wizard itself

      @wizard_pos += 1
      open_wizard_step
    end

    def wizard_back
      loop do
        @wizard_pos -= 1
        if @wizard_pos.negative?
          @wizard_pos = nil
          @plan = nil
          return
        end
        modal = build_step(@wizard[@wizard_pos])
        next if modal.nil?

        @modal = modal
        return
      end
    end

    def build_step(step)
      case step
      when :target then target_modal
      when :options then options_modal
      when :where then where_modal
      when :output then output_modal
      when :confirm then confirm_modal
      when :dest_where then dest_where_modal
      when :dest_name then dest_name_modal
      when :unpack_confirm then unpack_confirm_modal
      end
    end

    def apply_step(step, modal)
      case step
      when :target then @plan.target = modal.result
      when :where
        @where = modal.index
        @where_text = modal.text
        # Only typed text expands ~ and $HOME; a browsed folder may contain a literal $.
        @plan.outdir = @where == 2 ? Rakpak.expand_dir(modal.result) : modal.result
      when :output
        @name_edited = true
        @plan.basename = modal.result
      when :confirm then launch
      when :dest_where
        @where = modal.index
        @where_text = modal.text
        @dest_parent = @where == 2 ? Rakpak.expand_dir(modal.result) : modal.result
        sync_dest
      when :dest_name
        @dest_name = modal.result
        sync_dest
      when :unpack_confirm then launch
      end
    end

    def target_modal
      tar_ok = Tools.available?("tar")
      comp_ok = @plan.tar_choices.any? { |c| c[2] }
      zip_ok = @plan.compress_choices.any? { |c| c[2] }
      n = @plan.paths.size
      what = n == 1 ? File.basename(@plan.paths.first) : "#{n} items"
      SelectModal.new(
        title: "archive #{what}",
        items: [
          SelectModal::Item.new(label: "compressed tarball", value: :both, enabled: tar_ok && comp_ok,
                                why: tar_ok ? "no compressor installed" : "tar not installed",
                                blurb: ".tar.gz by default; zstd, xz and friends on offer"),
          SelectModal::Item.new(label: "plain tarball", value: :tar, enabled: tar_ok,
                                why: "tar not installed",
                                blurb: ".tar, no compression"),
          SelectModal::Item.new(label: "zip archive", value: :zip, enabled: zip_ok,
                                why: "no usable compressor here",
                                blurb: ".zip, or a lone file gzipped, zstd, xz")
        ],
        index: Plan::TARGETS.index(@plan.target) || 0,
        footer: "j/k move · enter choose · esc cancel"
      )
    end

    def options_modal
      case @plan.target
      when :both
        codec_form(@plan.tar, title: "compression", label: "compression",
                   flags_label: "tar flags")
      when :tar
        rows = [FormModal::Row.new(kind: :label, label: "tar flags")] + toggle_rows(@plan.tar_flags)
        FormModal.new(title: "tarball options", rows: rows)
      else
        codec_form(@plan.compress, title: "compression", label: "method",
                   flags_label: "zip flags", flags_when_container: true)
      end
    end

    def codec_form(side, title:, label:, flags_label:, flags_when_container: false)
      rows = [
        FormModal::Row.new(kind: :choice, label: label, hint: "", values: side.choices,
                           get: -> { side.codec.id }, set: ->(id) { side.codec = id }),
        FormModal::Row.new(kind: :number, label: "level", hint: "",
                           values: side.codec.levels || (0..0),
                           get: -> { side.level || 0 }, set: ->(v) { side.level = v })
      ]
      extra = [FormModal::Row.new(kind: :spacer),
               FormModal::Row.new(kind: :label, label: flags_label)] + toggle_rows(side.flags)
      DynamicForm.new(title: title, rows: rows, extra: extra, side: side,
                      extra_when_container: flags_when_container)
    end

    def toggle_rows(flags)
      flags.map do |f|
        FormModal::Row.new(kind: :toggle, label: f.label, hint: f.blurb,
                           get: -> { f.on }, set: ->(v) { f.on = v })
      end
    end

    def where_modal
      WhereModal.new(here: @browser.cwd, home: Dir.home, index: @where, text: @where_text,
                     validate: method(:writable_folder))
    end

    def writable_folder(text)
      d = Rakpak.expand_dir(text)
      if !File.directory?(d) then "not a folder: #{d}"
      elsif !File.writable?(d) then "not writable: #{d}"
      end
    end

    def dest_where_modal
      WhereModal.new(here: @browser.cwd, home: Dir.home, index: @where, text: @where_text,
                     validate: method(:writable_folder), title: "unpack it where?")
    end

    def dest_name_modal
      return nil if @plan.single?

      InputModal.new(title: "unpack into",
                     value: @dest_name,
                     hint: "a new folder in #{Text.tilde(@dest_parent)}  ·  . unpacks straight in",
                     validate: lambda { |name|
                       if name.include?("/") then "just a name, no slashes; the folder was picked already"
                       elsif name.include?("\0") || name == ".." then "not a valid name"
                       end
                     })
    end

    def sync_dest
      @plan.dest = @dest_name == "." ? @dest_parent : File.join(@dest_parent, @dest_name)
    end

    def unpack_confirm_modal
      lines = [[:head, "unpacks #{Text.tilde(@plan.archive)}"],
               [:key, ""],
               [:head, "into #{Text.tilde(@plan.dest)}"],
               [:key, ""]]
      @plan.preview.each do |label, cmd|
        lines << [:head, "#{label}:"]
        lines << [:cmd, "   #{cmd}"]
      end
      lines << [:key, ""]
      ConfirmModal.new(title: "ready", lines: lines,
                       warnings: @plan.warnings, errors: @plan.problems)
    end

    def output_modal
      @plan.basename = default_basename(@plan.paths) unless @name_edited
      InputModal.new(title: "output name",
                     value: @plan.basename,
                     hint: "in #{Text.tilde(@plan.outdir)}  ·  #{@plan.ext} added automatically",
                     validate: lambda { |name|
                       if name.include?("/") then "just a name, no slashes; the folder was picked already"
                       elsif name.include?("\0") || [".", ".."].include?(name) then "not a valid name"
                       end
                     })
    end

    def confirm_modal
      lines = []
      lines << [:head, "#{@plan.paths.size} item#{'s' unless @plan.paths.size == 1} " \
                       "from #{Text.tilde(@plan.base)}"]
      @plan.members.first(6).each { |m| lines << [:key, "   #{m}"] }
      lines << [:key, "   … #{@plan.members.size - 6} more"] if @plan.members.size > 6
      lines << [:key, ""]
      lines << [:head, "writes #{Text.tilde(@plan.output)}"]
      lines << [:key, ""]
      @plan.preview.each do |label, cmd|
        lines << [:head, "#{label}:"]
        lines << [:cmd, "   #{cmd}"]
      end
      lines << [:key, ""]
      ConfirmModal.new(title: "ready", lines: lines,
                       warnings: @plan.warnings, errors: @plan.problems)
    end

    def finish_wizard
      @wizard_pos = nil
    end

    def launch
      job = Job.new(@plan, total_files: @plan.total_members(@sizer)).start
      @jobs << job
      @focus_job = job
      @wizard_pos = nil
      @mode = :job
    end

    def reap_jobs
      @jobs.each do |j|
        next if j.running? || @reported_jobs[j]

        @reported_jobs[j] = true
        @browser.refresh!
        next if @mode == :job && @focus_job == j

        case j.state
        when :done then notify("✓ #{j.plan.outcome}", Theme::OK, 8)
        when :failed then notify("✗ #{j.error}", Theme::ERR, 10)
        when :cancelled then notify("cancelled", Theme::WARN)
        end
      end
    end

    def open_tags
      list = @browser.tags.to_a.sort
      modal = TagsModal.new(tags: list, sizer: @sizer)
      @modal = modal
      @tags_ref = list
    end

    def open_jobs
      if @jobs.empty?
        notify("no jobs yet", Theme::DIM)
        return
      end
      @focus_job = @jobs.reverse.find(&:running?) || @jobs.last
      @mode = :job
    end

    def open_help
      keys = [
        ["j k ↑ ↓", "move"],
        ["l → enter", "enter folder"], ["h ←", "leave folder"],
        ["g g", "top"], ["G", "bottom"], ["ctrl-d ctrl-u", "half page"],
        ["g h", "home"], ["g r", "root"], ["~", "home"],
        ["space", "tag / untag, then move down"],
        ["a", "tag everything here"], ["d", "untag everything here"],
        ["D", "clear all tags"], ["T", "review tagged items"],
        ["t", "show / hide the queue pane"],
        ["/", "filter this folder"], [".", "show hidden"],
        ["ctrl-r", "reload"],
        ["p", "pack: archive the tagged items"],
        ["u", "unpack the archive under the cursor"],
        ["b", "watch running jobs"], ["q", "quit"]
      ]
      w = keys.map { |k, _| Text.width(k) }.max
      lines = keys.map { |k, v| "#{Text.pad(k, w)}   #{v}" }
      @modal = MessageModal.new(title: "keys", lines: lines, style: Theme::NORMAL)
    end

    def request_quit
      running = @jobs.count(&:running?)
      if running.positive?
        @modal = ConfirmModal.new(
          title: "jobs still running",
          lines: [[:head, "#{running} job#{'s' unless running == 1} still running."],
                  [:key, ""],
                  [:key, "Quitting stops them and leaves partial archives behind."]],
          footer: "enter quit anyway · esc stay"
        )
        @quit_confirm = true
      else
        @quit = true
      end
    end

    def report
      done = @jobs.select(&:ok?)
      return if done.empty?

      done.each do |j|
        # Printed to the shell after the TUI exits, so defang escape sequences in names.
        puts "#{Text.plain(j.plan.outputs.first)}  #{Text.plain(j.plan.report_note)}"
      end
    end
  end

  class DynamicForm < FormModal
    def initialize(title:, rows:, side:, extra: [], extra_when_container: false)
      super(title: title, rows: rows + extra)
      @base = rows
      @extra = extra
      @side = side
      @conditional = extra_when_container
    end

    def draw(screen)
      sync_rows
      super
    end

    def sync_rows
      codec = @side.codec
      @rows = !@conditional || codec.container? ? @base + @extra : @base
      @index = @index.clamp(0, [@rows.size - 1, 0].max)
      @rows[0].hint = codec.blurb.to_s
      level = @rows[1]
      level.values = codec.levels || (0..0)
      level.hint = codec.levels ? "higher = smaller, slower" : "not adjustable"
    end
  end
end
