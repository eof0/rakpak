# frozen_string_literal: true

module Rakpak
  module Tools
    module_function

    def which(bin)
      return @which[bin] if defined?(@which) && @which&.key?(bin)

      @which ||= {}
      @which[bin] = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).lazy
                       .map { |d| File.join(d, bin) }
                       .find { |p| File.file?(p) && File.executable?(p) }
    end

    def available?(bin) = !which(bin).nil?

    # Info-ZIP reports its compiled-in methods in `zip -v`.
    def zip_has_bzip2?
      return @zip_bz2 if defined?(@zip_bz2)

      @zip_bz2 = available?("zip") && `zip -v 2>/dev/null`.include?("BZIP2_SUPPORT")
    rescue StandardError
      @zip_bz2 = false
    end

    # GNU tar, bsdtar (macOS) and busybox tar disagree about flags.
    def tar_flavor
      return @tar_flavor if defined?(@tar_flavor)

      @tar_flavor =
        if !available?("tar") then :missing
        else
          v = begin
            `tar --version 2>/dev/null`
          rescue StandardError
            ""
          end
          case v
          when /GNU tar/ then :gnu
          when /bsdtar|libarchive/ then :bsd
          when /busybox/i then :busybox
          else v.empty? ? :busybox : :unknown
          end
        end
    end

    # Long form works on GNU tar and bsdtar; -I is GNU-only.
    def tar_pipes? = %i[gnu bsd unknown].include?(tar_flavor)

  end

  Codec = Struct.new(:id, :label, :ext, :bin, :levels, :default, :threads, :blurb,
                     :level_opt, keyword_init: true) do
    def available? = bin.nil? || Tools.available?(bin)

    def why_not = available? ? nil : "#{bin} not installed"
    def container? = false

    def single_ext = ext.delete_prefix(".tar")

    def argv(level)
      return nil if bin.nil?

      parts = [bin, "-c"]
      # brotli's short -N form only accepts 0-9; 10 and 11 need -q N.
      parts.concat(level_opt ? [level_opt, level.to_s] : ["-#{level}"]) if levels && level
      parts.concat(threads) if threads
      parts
    end

    # tar splits --use-compress-program on spaces itself; GNU tar and bsdtar both accept it.
    def filter(level) = argv(level)&.join(" ")
  end

  TAR_CODECS = [
    Codec.new(id: :none,  label: "none",  ext: ".tar",     bin: nil,
              levels: nil,   default: nil, blurb: "no compression, fastest"),
    Codec.new(id: :gzip,  label: "gzip",  ext: ".tar.gz",  bin: "gzip",
              levels: 1..9,  default: 6,  blurb: "universal, safe default"),
    Codec.new(id: :zstd,  label: "zstd",  ext: ".tar.zst", bin: "zstd",
              levels: 1..19, default: 3,  threads: ["-T0"],
              blurb: "best speed/ratio balance"),
    Codec.new(id: :xz,    label: "xz",    ext: ".tar.xz",  bin: "xz",
              levels: 0..9,  default: 6,  threads: ["-T0"],
              blurb: "smallest output, slow"),
    Codec.new(id: :bzip2, label: "bzip2", ext: ".tar.bz2", bin: "bzip2",
              levels: 1..9,  default: 9,  blurb: "legacy, slow"),
    Codec.new(id: :lz4,   label: "lz4",   ext: ".tar.lz4", bin: "lz4",
              levels: 1..12, default: 1,  blurb: "extremely fast, low ratio"),
    Codec.new(id: :brotli, label: "brotli", ext: ".tar.br", bin: "brotli",
              levels: 0..11, default: 11, level_opt: "-q", blurb: "great on text")
  ].freeze

  def self.tar_codec(id) = TAR_CODECS.find { |c| c.id == id }

  ZipMethod = Struct.new(:id, :label, :flag, :levels, :default, :blurb, keyword_init: true) do
    def available?
      flag == "bzip2" ? Tools.zip_has_bzip2? : Tools.available?("zip")
    end

    def why_not
      return nil if available?
      return "zip not installed" unless Tools.available?("zip")

      "this zip lacks BZIP2_SUPPORT"
    end

    def container? = true
  end

  ZIP_METHODS = [
    ZipMethod.new(id: :zip, label: "zip", flag: "deflate", levels: 0..9, default: 6,
                  blurb: ".zip with deflate; reads everywhere"),
    ZipMethod.new(id: :zip_bzip2, label: "zip (bzip2)", flag: "bzip2", levels: 1..9, default: 9,
                  blurb: "smaller .zip, needs a modern unzip"),
    ZipMethod.new(id: :zip_store, label: "zip (store)", flag: "store", levels: nil, default: nil,
                  blurb: ".zip with no compression")
  ].freeze

  COMPRESSORS = (ZIP_METHODS + TAR_CODECS.reject { |c| c.id == :none }).freeze

  def self.compressor(id) = COMPRESSORS.find { |c| c.id == id }

  Flag = Struct.new(:id, :label, :args, :on, :blurb, :needs, keyword_init: true) do
    def supported?(flavor) = needs.nil? || needs.include?(flavor)
  end

  GNU  = %i[gnu unknown].freeze
  BOTH = %i[gnu bsd unknown].freeze
  ALL  = %i[gnu bsd busybox unknown].freeze

  def self.tar_flags(flavor = Tools.tar_flavor)
    [
      Flag.new(id: :verbose, label: "verbose", args: ["-v"], on: true, needs: ALL,
               blurb: "list each file (drives the progress readout)"),
      Flag.new(id: :preserve, label: "preserve permissions", args: ["-p"], on: true, needs: BOTH,
               blurb: "keep modes exactly as on disk"),
      Flag.new(id: :xattrs, label: "extended attributes", args: ["--xattrs", "--acls"], on: false, needs: BOTH,
               blurb: "store xattrs and POSIX ACLs"),
      Flag.new(id: :deref, label: "follow symlinks", args: ["-h"], on: false, needs: BOTH,
               blurb: "archive link targets instead of the links"),
      Flag.new(id: :onefs, label: "one file system", args: ["--one-file-system"], on: false, needs: BOTH,
               blurb: "do not cross mount points"),
      Flag.new(id: :numeric, label: "numeric owner", args: ["--numeric-owner"], on: false, needs: BOTH,
               blurb: "store uid/gid, not names"),
      Flag.new(id: :sparse, label: "sparse files", args: ["-S"], on: false, needs: GNU,
               blurb: "store holes efficiently"),
      Flag.new(id: :excl_vcs, label: "exclude VCS dirs", args: ["--exclude-vcs"], on: false, needs: GNU,
               blurb: "skip .git, .hg, .svn"),
      Flag.new(id: :excl_ign, label: "honour .gitignore", args: ["--exclude-vcs-ignores"], on: false, needs: GNU,
               blurb: "skip files your VCS ignores"),
      Flag.new(id: :sorted, label: "reproducible order", args: ["--sort=name"], on: false, needs: GNU,
               blurb: "deterministic member order"),
      Flag.new(id: :keepgoing, label: "ignore read errors", args: ["--ignore-failed-read"], on: false, needs: GNU,
               blurb: "do not abort on unreadable files")
    ].select { |f| f.supported?(flavor) }
  end

  def self.zip_flags
    [
      Flag.new(id: :verbose, label: "verbose", args: [], on: true,
               blurb: "list each file (drives the progress readout)"),
      Flag.new(id: :symlinks, label: "store symlinks", args: ["-y"], on: true,
               blurb: "keep links as links, do not follow"),
      Flag.new(id: :dirs, label: "directory entries", args: [], on: true,
               blurb: "record folders explicitly"),
      Flag.new(id: :junk, label: "junk paths", args: ["-j"], on: false,
               blurb: "flatten everything into the root"),
      Flag.new(id: :noextra, label: "strip extra attributes", args: ["-X"], on: false,
               blurb: "no uid/gid or timestamps beyond the basics"),
      Flag.new(id: :oldest, label: "archive time = newest entry", args: ["-o"], on: false,
               blurb: "reproducible-ish archive mtime")
    ]
  end
end
