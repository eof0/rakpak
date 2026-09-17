# frozen_string_literal: true

require_relative "rakpak/version"
require_relative "rakpak/unpack"
require_relative "rakpak/app"

module Rakpak
  USAGE = <<~USAGE
    rakpak: tag files anywhere, archive them once.

    usage: rakpak [folder]
           rakpak -p path [path ...]
           rakpak -d archive [archive ...]

      folder         start browsing there (default: your home folder)
      -p, --pack     tag the given files or folders and go straight to the
                     archive prompts, starting with the kind of compression
      -d, --depack   unpack the archives here and now, no browsing: each one
                     into a folder of its own name in the current folder
      -h, --help     this text
      -v, --version  print the version

      space      tag / untag       p    pack what is tagged
      h l ← →   navigate           u    unpack what the cursor is on
      enter      enter folder       /    filter      .  hidden
      ?          all keys           T    review tags       q  quit
  USAGE

  Options = Struct.new(:dir, :pack, :unpack, :action, keyword_init: true)

  def self.expand_dir(text)
    text = text.to_s.strip
    text = text.gsub(/\$\{(\w+)\}|\$(\w+)/) { ENV.fetch(::Regexp.last_match(1) || ::Regexp.last_match(2), "") }
    text = "~" if text.empty?
    File.expand_path(text)
  rescue ArgumentError
    text
  end

  def self.parse(argv)
    pack_mode = false
    depack_mode = false
    positional = []
    rest = argv.dup
    until rest.empty?
      arg = rest.shift
      case arg
      when "-h", "--help" then return Options.new(action: :help)
      when "-v", "--version" then return Options.new(action: :version)
      when "-p", "--pack" then pack_mode = true
      when "-d", "--depack", "--unpack" then depack_mode = true
      when "--" then positional.concat(rest) && rest.clear
      when /\A-./ then raise ArgumentError, "unknown option: #{arg}"
      else positional << arg
      end
    end

    raise ArgumentError, "-p and -d do different things; pick one" if pack_mode && depack_mode

    if depack_mode
      raise ArgumentError, "-d needs at least one archive" if positional.empty?

      paths = positional.map { |p| File.expand_path(p) }
      paths.each do |p|
        raise ArgumentError, "no such file: #{p}" unless File.exist?(p)
        unless File.file?(p) && Unpack.archive?(p)
          raise ArgumentError, "not an archive rakpak knows how to open: #{File.basename(p)}"
        end
      end
      return Options.new(action: :unpack, unpack: paths, pack: [])
    end

    if pack_mode
      raise ArgumentError, "-p needs at least one path" if positional.empty?

      paths = positional.map { |p| File.expand_path(p) }
      paths.each do |p|
        raise ArgumentError, "no such file or folder: #{p}" unless File.exist?(p) || File.symlink?(p)
      end
      Options.new(action: :browse, dir: File.dirname(paths.first), pack: paths, unpack: [])
    else
      raise ArgumentError, "expected one folder, got #{positional.size}" if positional.size > 1

      dir = File.expand_path(positional.first || Dir.home)
      raise ArgumentError, "not a folder: #{dir}" unless File.directory?(dir)

      Options.new(action: :browse, dir: dir, pack: [], unpack: [])
    end
  end

  def self.unpack_all(archives, dir: Dir.pwd, out: $stdout)
    status = 0
    archives.each do |archive|
      sub = Unpack.default_subdir(archive)
      plan = Unpack.new(archive: archive, dest: sub ? File.join(dir, sub) : dir)
      problems = plan.problems
      if problems.any?
        problems.each { |m| warn "rakpak: #{m}" }
        status = 1
        next
      end
      out.puts "#{Text.plain(File.basename(archive))} → #{Text.plain(Text.tilde(plan.dest))}"
      plan.warnings.each { |w| out.puts "  #{w}" }
      # The job writes to stderr; flush so the streams stay in order.
      out.flush
      status = 1 unless run_headless(plan, out)
    end
    status
  rescue Interrupt
    130
  end

  # The extractor runs in its own process group, so ctrl-c never reaches it;
  # catching Interrupt here is what stops tar carrying on without us.
  def self.run_headless(plan, out)
    job = Job.new(plan).start
    live = out.respond_to?(:tty?) && out.tty?
    begin
      while job.running?
        job.wait(0.1)
        next unless live

        out.print "\r  #{job.file_count} entries · #{Text.duration(job.elapsed)}\e[K"
        out.flush
      end
    rescue Interrupt
      out.print "\r\e[K" if live
      job.cancel
      job.wait(5)
      warn "rakpak: cancelled"
      raise
    end
    out.print "\r\e[K" if live
    unless job.ok?
      warn "rakpak: #{job.error}"
      # Member names come from inside the archive; defang before printing.
      job.tail(4).each { |line| warn "  #{Text.plain(line)}" unless line.start_with?("▸") }
      return false
    end
    out.puts "  #{job.file_count} entries · #{Text.duration(job.elapsed)} · #{plan.report_note}"
    true
  end

  def self.start(argv = ARGV)
    begin
      opts = parse(argv)
    rescue ArgumentError => e
      warn "rakpak: #{e.message}"
      warn "try: rakpak --help"
      return 2
    end
    case opts.action
    when :help
      puts USAGE
      return 0
    when :version
      puts "rakpak #{VERSION}"
      return 0
    when :unpack
      return unpack_all(opts.unpack)
    end
    unless $stdout.tty? && $stdin.tty?
      warn "rakpak: needs an interactive terminal"
      return 1
    end
    App.new(opts.dir, pack: opts.pack).run
    0
  end
end
