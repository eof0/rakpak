# frozen_string_literal: true

require "fileutils"
require_relative "formats"
require_relative "plan"

module Rakpak
  # Turns one archive plus a destination into a command that unpacks it.
  # Wears the same face as Plan, so Job runs it without knowing which way
  # round the work goes.
  #
  # Three shapes, mirroring the ones Plan writes:
  #   :tar     tar, decompressing through the codec if there is one
  #   :zip     unzip
  #   :single  one compressed file back to one plain file
  class Unpack
    # An archive shape recognised by extension. `codec` names the TAR_CODECS
    # entry doing the compression, so the binary probing already done for
    # packing decides whether this can be read back.
    Shape = Struct.new(:ext, :kind, :codec, keyword_init: true) do
      def tool = kind == :zip ? "unzip" : "tar"

      # The compressor's binary, when one is involved.
      def bin = codec && Rakpak.tar_codec(codec)&.bin
    end

    # Longest extension first, so notes.tar.gz never reads as a bare .gz.
    SHAPES = [
      Shape.new(ext: ".tar",     kind: :tar),
      Shape.new(ext: ".tar.gz",  kind: :tar, codec: :gzip),
      Shape.new(ext: ".tar.zst", kind: :tar, codec: :zstd),
      Shape.new(ext: ".tar.xz",  kind: :tar, codec: :xz),
      Shape.new(ext: ".tar.bz2", kind: :tar, codec: :bzip2),
      Shape.new(ext: ".tar.lz4", kind: :tar, codec: :lz4),
      Shape.new(ext: ".tar.br",  kind: :tar, codec: :brotli),
      Shape.new(ext: ".tgz",     kind: :tar, codec: :gzip),
      Shape.new(ext: ".tzst",    kind: :tar, codec: :zstd),
      Shape.new(ext: ".txz",     kind: :tar, codec: :xz),
      Shape.new(ext: ".tbz2",    kind: :tar, codec: :bzip2),
      Shape.new(ext: ".tbz",     kind: :tar, codec: :bzip2),
      Shape.new(ext: ".zip",     kind: :zip),
      Shape.new(ext: ".gz",      kind: :single, codec: :gzip),
      Shape.new(ext: ".zst",     kind: :single, codec: :zstd),
      Shape.new(ext: ".xz",      kind: :single, codec: :xz),
      Shape.new(ext: ".bz2",     kind: :single, codec: :bzip2),
      Shape.new(ext: ".lz4",     kind: :single, codec: :lz4),
      Shape.new(ext: ".br",      kind: :single, codec: :brotli)
    ].sort_by { |s| -s.ext.length }.freeze

    # nil when the name carries no extension we know how to open.
    def self.format(path)
      name = File.basename(path.to_s).downcase
      SHAPES.find { |s| name.end_with?(s.ext) && name.length > s.ext.length }
    end

    def self.archive?(path) = !format(path).nil?

    # "notes.tar.gz" -> "notes"; the whole archive extension goes. A name that
    # leaves nothing, "." or ".." behind would resolve to the destination's
    # parent once joined, so those keep the whole basename instead.
    def self.strip_ext(path)
      name = File.basename(path.to_s)
      shape = format(path)
      stripped = shape ? name[0...-shape.ext.length] : name
      ["", ".", ".."].include?(stripped) ? name : stripped
    end

    # The folder to make for the contents, or nil when the archive holds a
    # single file that should land beside you.
    def self.default_subdir(path)
      format(path)&.kind == :single ? nil : strip_ext(path)
    end

    # What a lone compressed file decompresses back into.
    def self.member_name(path) = strip_ext(path)

    attr_reader :archive, :shape
    attr_accessor :dest

    def initialize(archive:, dest:)
      @archive = File.expand_path(archive)
      @dest = File.expand_path(dest)
      @shape = Unpack.format(@archive)
    end

    def kind = @shape&.kind
    def single? = kind == :single

    # Job chdirs here, so it has to exist by the time the first step runs.
    def base = @dest

    # A tarball or zip pours its members into the folder; a lone compressed
    # file has one real output, and Job may replace that.
    def outputs = [single? ? File.join(@dest, Unpack.member_name(@archive)) : @dest]
    def output = outputs.first
    def clobbers_output? = single?

    # The decompressor's output is opened for writing before it has read a
    # single byte of the archive, so it cannot be aimed at the file it is
    # meant to replace. It writes here and is renamed over the top on success.
    def scratch = File.join(@dest, ".#{Unpack.member_name(@archive)}.part")

    def prepare
      # Remember what we make, so a failure can leave the tree as it was.
      @made = []
      dir = @dest
      until File.directory?(dir) || dir == "/"
        @made << dir
        dir = File.dirname(dir)
      end
      FileUtils.mkdir_p(@dest)
    end

    # Every step succeeded, so the recovered file may take its real name.
    def commit
      File.rename(scratch, output) if single? && File.exist?(scratch)
    end

    # Folders we created and never filled are ours to take back; anything that
    # was already on disk, or anything the run managed to write, stays.
    def rollback
      (@made || []).each do |dir|
        Dir.rmdir(dir) if File.directory?(dir) && Dir.empty?(dir)
      rescue StandardError
        nil
      end
    end

    # Counting an archive's members means decompressing the whole thing
    # first, which is most of the work. The job counts up as it goes instead.
    def total_members(_sizer) = nil

    def gerund = "unpacking"

    # A recovered lone file can be weighed. A folder of members has no useful
    # size of its own, so it reports what happened instead.
    def outcome
      return "#{File.basename(output)} #{Text.bytes(file_size(output))}" if single?

      "unpacked into #{File.basename(@dest)}/"
    end

    def report_note = single? ? Text.bytes(file_size(output)) : "unpacked"

    def file_size(path)
      File.size(path)
    rescue StandardError
      nil
    end

    def tar_argv
      argv = ["tar", "-x", "-v"]
      # Reading an archive, GNU tar runs the program with -d appended, so it
      # gets the bare binary; adding our own -d makes brotli refuse the
      # command as already set. bsdtar runs the string as given, so it needs
      # the -d spelled out or the compressor compresses the stream again.
      argv += ["--use-compress-program", Tools.tar_flavor == :bsd ? "#{@shape.bin} -d" : @shape.bin] if @shape.bin
      argv + ["-f", @archive, "-C", @dest]
    end

    def zip_argv = ["unzip", "-o", @archive, "-d", @dest]

    # The compressor reading the archive and writing the plain file to
    # stdout, which Job points at the output path.
    def single_argv = [@shape.bin, "-dc", @archive]

    # [label, argv, expects_verbose_output, stdout_path]
    def steps
      case kind
      when :tar then [["tar", tar_argv, true, nil]]
      when :zip then [["unzip", zip_argv, true, nil]]
      when :single then [[@shape.bin, single_argv, false, scratch]]
      else []
      end
    end

    def preview
      steps.map { |(label, argv, _, stdout)| [label, Plan.show_cmd(argv, stdout)] }
    end

    def missing?(bin) = !Tools.available?(bin)

    # GNU tar and bsdtar can hand the stream to a compressor; busybox cannot.
    def tar_pipes? = Tools.tar_pipes?

    # Every tool this run needs, so a half-installed machine is caught on
    # the confirm screen rather than partway through the extraction.
    def tools = [@shape&.kind == :single ? nil : @shape&.tool, @shape&.bin].compact

    def problems
      return ["not an archive rakpak knows how to open: #{File.basename(@archive)}"] if @shape.nil?

      errs = []
      if !File.exist?(@archive) then errs << "no such file: #{@archive}"
      elsif !File.file?(@archive) then errs << "not a file: #{@archive}"
      elsif !File.readable?(@archive) then errs << "not readable: #{@archive}"
      end
      tools.each { |bin| errs << "#{bin} not installed" if missing?(bin) }
      if kind == :tar && @shape.bin && !tar_pipes?
        errs << "this tar cannot pipe through #{@shape.bin}"
      end
      # mkdir_p would raise EEXIST partway through the run; say it up front.
      errs << "not a folder: #{@dest}" if File.exist?(@dest) && !File.directory?(@dest)
      # A folder can be writable and still refuse to be listed, which tar
      # needs to do to avoid clobbering, and which warnings needs to read.
      if File.directory?(@dest) && !File.readable?(@dest)
        errs << "destination is not readable: #{@dest}"
      end
      parent = existing_parent(@dest)
      errs << "destination is not writable: #{parent}" unless File.writable?(parent)
      errs.uniq
    end

    # Nothing is created until the job runs, so writability is a question
    # about the nearest folder that already exists.
    def existing_parent(dir)
      dir = File.dirname(dir) until File.directory?(dir) || dir == "/"
      dir
    end

    def warnings
      warn = []
      if single?
        warn << "#{Unpack.member_name(@archive)} already exists and will be replaced" if File.exist?(output)
      elsif File.directory?(@dest) && !empty_dir?(@dest)
        warn << "#{File.basename(@dest)} already has files in it; matching names will be replaced"
      end
      warn
    end

    # An unlistable folder is reported by problems; there is nothing to warn
    # about and this must not raise, since the confirm screen draws it.
    def empty_dir?(dir)
      Dir.children(dir).empty?
    rescue StandardError
      true
    end
  end
end
