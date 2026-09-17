# frozen_string_literal: true

require_relative "formats"
require_relative "text"

module Rakpak
  # :both tar then compress, :tar plain tar, :zip compress only (name.zip, or name.txt.gz for one file)
  class Plan
    TARGETS = %i[both tar zip].freeze

    attr_reader :paths
    attr_accessor :outdir, :basename, :target
    attr_accessor :tar_codec, :tar_level, :tar_flags, :compressor, :comp_level, :zip_flags

    def initialize(paths:, outdir:, basename: "archive", target: :both)
      @paths = self.class.prune(paths)
      @outdir = outdir
      @basename = basename
      @target = target
      @tar_codec = TAR_CODECS.find { |c| c.id == :gzip && c.available? } || tar_codec_fallback
      @tar_level = @tar_codec.default
      @tar_flags = Rakpak.tar_flags
      @compressor = COMPRESSORS.find { |c| c.container? && c.available? } || COMPRESSORS.first
      @comp_level = @compressor.default
      @zip_flags = Rakpak.zip_flags
    end

    def self.prune(paths)
      # Sorting by components puts descendants right after their ancestor ("a/b" before "a-x").
      sorted = paths.map { |p| File.expand_path(p) }.uniq.sort_by { |p| p.split("/") }
      kept = []
      stack = []
      sorted.each do |p|
        stack.pop while stack.any? && !inside?(p, stack.last)
        next if stack.any?

        kept << p
        stack << p
      end
      kept
    end

    def self.inside?(path, dir)
      path.start_with?(dir == "/" ? "/" : "#{dir}/")
    end

    def tar_codec_fallback
      TAR_CODECS.find { |c| c.bin && c.available? } || Rakpak.tar_codec(:none)
    end

    class Side
      attr_reader :options, :flags

      def initialize(plan, options:, codec:, level:, flags:, choices:)
        @plan = plan
        @options = options
        @codec_attr = codec
        @level_attr = level
        @flags = flags
        @choices = choices
      end

      def codec = @plan.public_send(@codec_attr)
      def level = @plan.public_send(@level_attr)
      def level=(v)
        @plan.public_send("#{@level_attr}=", v)
      end

      # [label, id, enabled, why] rows.
      def choices = @plan.public_send(@choices)

      def codec=(id)
        c = @options.find { |o| o.id == id } or raise ArgumentError, "unknown codec #{id}"
        @plan.public_send("#{@codec_attr}=", c)
        self.level = c.default
      end
    end

    def tar
      Side.new(self, options: TAR_CODECS, codec: :tar_codec, level: :tar_level,
                     flags: @tar_flags, choices: :tar_choices)
    end

    def compress
      Side.new(self, options: COMPRESSORS, codec: :compressor, level: :comp_level,
                     flags: @zip_flags, choices: :compress_choices)
    end

    def tar_choices
      TAR_CODECS.reject { |c| c.id == :none }.map { |c| [c.label, c.id, c.available?, c.why_not] }
    end

    def compress_choices
      COMPRESSORS.map do |c|
        ok = c.available? && (c.container? || single_file?)
        why = c.why_not || "compresses one file only; choose both for folders"
        [c.label, c.id, ok, ok ? nil : why]
      end
    end

    def single_file? = @paths.size == 1 && File.file?(@paths.first)

    def single_compress? = @target == :zip && !@compressor.container?

    def base
      @base ||= begin
        dirs = @paths.map { |p| File.dirname(p) }
        common = dirs.first.to_s.split("/")
        dirs.each do |d|
          parts = d.split("/")
          i = 0
          i += 1 while i < common.size && i < parts.size && common[i] == parts[i]
          common = common[0...i]
        end
        c = common.join("/")
        c.empty? ? "/" : c
      end
    end

    def members
      @paths.map do |p|
        rel = p.delete_prefix(base == "/" ? "/" : "#{base}/")
        rel.empty? ? File.basename(p) : rel
      end
    end

    def ext
      case @target
      when :both then @tar_codec.ext
      when :tar then ".tar"
      else @compressor.container? ? ".zip" : @compressor.single_ext
      end
    end

    def output = File.join(@outdir, ensure_ext(@basename, ext))
    def outputs = [output]

    def prepare; end
    def commit; end
    def rollback; end

    def gerund = "archiving"

    def outcome
      outputs.map { |o| "#{File.basename(o)} #{Text.bytes(file_size(o))}" }.join(" · ")
    end

    def report_note = Text.bytes(file_size(output))

    def file_size(path)
      File.size(path)
    rescue StandardError
      nil
    end

    def total_members(sizer)
      files = sizer.total(@paths).files
      files.positive? ? files : nil
    end

    def clobbers_output? = true

    ARCHIVE_EXTS = (TAR_CODECS.map(&:ext) + TAR_CODECS.map(&:single_ext) + %w[.tgz .tbz2 .txz .zip])
                   .reject(&:empty?).uniq.sort_by { |e| -e.length }.freeze

    def ensure_ext(name, ext)
      return name if name.downcase.end_with?(ext)
      return "#{name}#{ext}" if single_compress?

      typed = ARCHIVE_EXTS.find { |e| name.downcase.end_with?(e) }
      stripped = typed ? name[0...-typed.length] : name
      stripped = name if stripped.empty?
      "#{stripped}#{ext}"
    end

    def tar_argv
      argv = ["tar", "-c"]
      if @target == :both && (filter = @tar_codec.filter(@tar_level))
        argv += ["--use-compress-program", filter]
      end
      @tar_flags.each { |f| argv.concat(f.args) if f.on }
      argv += ["-f", output, "-C", base, "--"]
      argv + members
    end

    def zip_argv
      argv = ["zip", "-r"]
      argv << (zip_verbose? ? "-v" : "-q")
      argv << "-Z" << @compressor.flag if @compressor.flag != "deflate"
      argv << "-#{@comp_level.clamp(0, 9)}" if @compressor.levels && @comp_level
      argv << "-D" unless flag_on?(@zip_flags, :dirs)
      @zip_flags.each do |f|
        next if %i[verbose dirs].include?(f.id)

        argv.concat(f.args) if f.on
      end
      argv << output
      argv + members.map { |m| dashsafe(m) }
    end

    def single_argv
      @compressor.argv(@comp_level) + [dashsafe(members.first)]
    end

    def dashsafe(name) = name.start_with?("-") ? "./#{name}" : name

    def zip_verbose? = flag_on?(@zip_flags, :verbose)
    def tar_verbose? = flag_on?(@tar_flags, :verbose)

    def flag_on?(list, id)
      f = list.find { |x| x.id == id }
      f ? f.on : false
    end

    # [label, argv, expects_verbose_output, stdout_path]
    def steps
      case @target
      when :both, :tar then [["tar", tar_argv, tar_verbose?, nil]]
      else
        if @compressor.container?
          [["zip", zip_argv, zip_verbose?, nil]]
        else
          [[@compressor.label, single_argv, false, output]]
        end
      end
    end

    # Display only; execution never goes through a shell.
    def self.show_arg(arg)
      arg.match?(%r{\A[\w@%+=:,./-]+\z}) ? arg : "'#{arg.gsub("'", %q('"'"'))}'"
    end

    def self.show_cmd(argv, stdout = nil)
      cmd = argv.map { |a| show_arg(a) }.join(" ")
      stdout ? "#{cmd} > #{show_arg(stdout)}" : cmd
    end

    def preview
      steps.map { |(label, argv, _, stdout)| [label, Plan.show_cmd(argv, stdout)] }
    end

    def problems
      errs = []
      errs << "nothing selected" if @paths.empty?
      errs << "destination is not a folder: #{@outdir}" unless File.directory?(@outdir)
      errs << "destination is not writable: #{@outdir}" if File.directory?(@outdir) && !File.writable?(@outdir)
      case @target
      when :both
        errs << "tar is not installed" unless Tools.available?("tar")
        errs << @tar_codec.why_not if @tar_codec.why_not
        errs << "no compressor installed; choose tarball" if @tar_codec.id == :none
      when :tar
        errs << "tar is not installed" unless Tools.available?("tar")
      else
        errs << @compressor.why_not if @compressor.why_not
        if !@compressor.container? && !single_file?
          errs << "#{@compressor.label} compresses one file only; choose both for folders"
        end
      end
      errs.compact.uniq
    end

    def warnings
      warn = []
      o = output
      warn << "#{File.basename(o)} already exists and will be replaced" if File.exist?(o)
      if @paths.any? { |p| Plan.inside?(o, p) }
        warn << "output sits inside a selected folder, so it may archive itself"
      end
      warn
    end
  end
end
