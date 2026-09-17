# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require "rakpak"

class TextTest < Minitest::Test
  T = Rakpak::Text

  def test_width_counts_wide_and_zero_width
    assert_equal 4, T.width("abcd")
    assert_equal 4, T.width("日本")
    assert_equal 0, T.width("́")
  end

  def test_fit_appends_ellipsis_only_when_cutting
    assert_equal "abc", T.fit("abc", 5)
    assert_equal "ab…", T.fit("abcdef", 3)
    assert_equal "", T.fit("abc", 0)
  end

  def test_fit_left_keeps_the_tail
    assert_equal "…def", T.fit_left("abcdef", 4)
  end

  def test_wrap_indents_continuations_and_breaks_long_words
    lines = T.wrap("   cmd aaa bbb ccc", 12, 5)
    assert_equal "   cmd aaa", lines.first
    assert lines[1].start_with?("     ")

    long = T.wrap("x" * 40, 20, 5)
    assert(long.all? { |l| T.width(l) <= 20 })
  end

  def test_bytes_and_duration
    assert_equal "512B", T.bytes(512)
    assert_equal "1.0K", T.bytes(1024)
    assert_equal "-", T.bytes(nil)
    assert_equal "1:05", T.duration(65)
    assert_equal "1:00:00", T.duration(3600)
  end
end

class ScreenTest < Minitest::Test
  def setup
    @s = Rakpak::Screen.new(20, 3) # 20 is the enforced minimum width
  end

  def plain = @s.render.gsub(/\e\[[0-9;]*[A-Za-z]/, "").split("\r\n")

  def test_put_and_render
    @s.clear
    @s.put(2, 1, "hi")
    assert_equal "  hi" + (" " * 16), plain[1]
  end

  def test_wide_char_consumes_two_cells
    @s.clear
    @s.put(0, 0, "日x")
    assert_equal "日x" + (" " * 17), plain[0]
  end

  def test_writes_are_clipped_not_wrapped
    @s.clear
    @s.put(16, 0, "abcdef")
    assert_equal "#{' ' * 16}abcd", plain[0]
    assert_equal " " * 20, plain[1], "text must clip, never spill onto the next row"
  end

  def test_box_draws_a_frame
    @s.clear
    @s.box(0, 0, 4, 3)
    assert_equal "╭──╮#{' ' * 16}", plain[0]
    assert_equal "╰──╯#{' ' * 16}", plain[2]
  end
end

class PlanTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    FileUtils.mkdir_p("#{@dir}/a/b")
    FileUtils.mkdir_p("#{@dir}/c")
    File.write("#{@dir}/a/b/f.txt", "x")
    File.write("#{@dir}/c/g.txt", "y")
  end

  def teardown = FileUtils.remove_entry(@dir)

  def plan(paths, **kw)
    Rakpak::Plan.new(paths: paths, outdir: @dir, basename: "out", **kw)
  end

  def test_base_is_the_common_parent
    p = plan(["#{@dir}/a/b", "#{@dir}/c"])
    assert_equal @dir, p.base
    assert_equal ["a/b", "c"], p.members
  end

  def test_single_selection_bases_on_its_parent
    p = plan(["#{@dir}/a/b/f.txt"])
    assert_equal "#{@dir}/a/b", p.base
    assert_equal ["f.txt"], p.members
  end

  def test_extension_is_appended_and_competing_ones_replaced
    p = plan(["#{@dir}/c"], target: :both)
    p.tar_codec = Rakpak.tar_codec(:gzip)
    assert_equal "out.tar.gz", File.basename(p.output)

    p.basename = "out.zip"
    assert_equal "out.tar.gz", File.basename(p.output)

    p.basename = "out.tar.gz"
    assert_equal "out.tar.gz", File.basename(p.output)
  end

  def test_nested_tags_are_not_archived_twice
    p = plan(["#{@dir}/a", "#{@dir}/a/b"])
    assert_equal ["a"], p.members
  end

  def test_zip_level_never_exceeds_what_the_cli_understands
    p = plan(["#{@dir}/c"], target: :zip)
    p.comp_level = 19 # zip would read this as "-1 -9" and say nothing
    refute(p.zip_argv.any? { |a| a.match?(/\A-\d\d/) },
           "zip only understands single-digit levels")
  end

  def test_argv_is_never_shell_interpreted
    File.write("#{@dir}/c/we ird;name", "z")
    p = plan(["#{@dir}/c/we ird;name"], target: :tar)
    assert_includes p.tar_argv, "we ird;name"
    assert_includes p.tar_argv, "--"
  end

  def test_problems_flags_an_unwritable_destination
    ro = File.join(@dir, "ro")
    FileUtils.mkdir_p(ro)
    File.chmod(0o500, ro)
    p = Rakpak::Plan.new(paths: ["#{@dir}/c"], outdir: ro, basename: "x")
    assert(p.problems.any? { |m| m.include?("not writable") })
  ensure
    File.chmod(0o700, ro) if ro
  end

  def test_warnings_catch_overwrite_and_self_inclusion
    p = plan(["#{@dir}/c"], target: :tar)
    File.write(p.output, "")
    assert(p.warnings.any? { |w| w.include?("already exists") })

    inner = Rakpak::Plan.new(paths: [@dir], outdir: @dir, basename: "self", target: :tar)
    assert(inner.warnings.any? { |w| w.include?("archive itself") })
  end
end

class FormatsTest < Minitest::Test
  def test_flags_are_gated_by_tar_flavour
    gnu = Rakpak.tar_flags(:gnu).map(&:id)
    bsd = Rakpak.tar_flags(:bsd).map(&:id)
    busybox = Rakpak.tar_flags(:busybox).map(&:id)

    assert_includes gnu, :excl_vcs
    refute_includes bsd, :excl_vcs, "bsdtar has no --exclude-vcs"
    assert_equal [:verbose], busybox
    assert (gnu - bsd).any?
  end

  def test_codec_filter_string
    gz = Rakpak.tar_codec(:gzip)
    assert_equal "gzip -c -6", gz.filter(6)
    assert_nil Rakpak.tar_codec(:none).filter(nil)
  end

  def test_every_unavailable_method_gives_a_reason
    (Rakpak::ZIP_METHODS + Rakpak::TAR_CODECS).each do |m|
      if m.available?
        assert_nil m.why_not, "#{m.label} is available but claims a reason"
      else
        refute_empty m.why_not.to_s, "#{m.label} is unavailable with no reason"
      end
    end
  end

def test_single_file_compressors_are_only_offered_for_a_lone_file
  dir = Dir.mktmpdir("rakpak")
  FileUtils.mkdir_p("#{dir}/folder")
  File.write("#{dir}/one.txt", "x")
  folder = Rakpak::Plan.new(paths: ["#{dir}/folder"], outdir: dir, target: :zip)
  lone = Rakpak::Plan.new(paths: ["#{dir}/one.txt"], outdir: dir, target: :zip)
  gz = ->(p) { p.compress_choices.find { |c| c[1] == :gzip } }
  refute gz.call(folder)[2], "gzip cannot take a folder"
  assert_match(/one file only/, gz.call(folder)[3])
  assert_equal Rakpak.tar_codec(:gzip).available?, gz.call(lone)[2]
  assert folder.compress_choices.find { |c| c[1] == :zip }[2] if Rakpak::Tools.available?("zip")
ensure
  FileUtils.remove_entry(dir)
end

  def test_brotli_uses_the_q_form_for_levels_above_nine
    br = Rakpak.tar_codec(:brotli)
    assert_equal "brotli -c -q 11", br.filter(11),
                 "brotli -11 is rejected by the CLI as 'quality already set'"
    assert_equal "gzip -c -9", Rakpak.tar_codec(:gzip).filter(9)
  end
end

class BrowserTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    FileUtils.mkdir_p("#{@dir}/sub")
    File.write("#{@dir}/alpha.txt", "a")
    File.write("#{@dir}/beta.txt", "b")
    File.write("#{@dir}/.hidden", "h")
    @b = Rakpak::Browser.new(@dir)
  end

  def teardown = FileUtils.remove_entry(@dir)

  def test_hidden_files_are_opt_in
    refute_includes @b.entries.map(&:name), ".hidden"
    @b.handle(".")
    assert_includes @b.entries.map(&:name), ".hidden"
  end

  def test_folders_sort_first
    assert_equal "sub", @b.entries.first.name
  end

  def test_space_tags_and_advances
    @b.handle(:space)
    assert_equal ["#{@dir}/sub"], @b.tags.to_a
    assert_equal 1, @b.index
  end

  def test_selection_falls_back_to_the_cursor
    assert_equal ["#{@dir}/sub"], @b.selection
    @b.handle(:space)
    @b.handle(:space)
    assert_equal 2, @b.tags.size
  end

  def test_navigation_remembers_position
    @b.handle("l")
    assert_equal "#{@dir}/sub", @b.cwd
    @b.handle("h")
    assert_equal @dir, @b.cwd
    assert_equal "sub", @b.current.name
  end

  def test_filter_narrows_the_listing
    @b.handle("/")
    "beta".each_char { |c| @b.handle(c) }
    assert_equal ["beta.txt"], @b.entries.map(&:name)
    @b.handle(:esc)
    assert_equal 3, @b.entries.size
  end

  def test_p_requests_archiving
    assert_equal :archive, @b.handle("p")
    assert_equal :quit, @b.handle("q")
  end

  def test_enter_descends_like_yazi
    assert_nil @b.handle(:enter), "enter must never trigger the wizard"
    assert_equal "#{@dir}/sub", @b.cwd

    @b.handle(:left)
    assert_equal @dir, @b.cwd
  end

  def test_arrows_mirror_hjkl
    @b.handle(:down)
    assert_equal 1, @b.index
    @b.handle(:up)
    assert_equal 0, @b.index

    @b.handle(:right)
    assert_equal "#{@dir}/sub", @b.cwd
  end
end

class JobTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    FileUtils.mkdir_p("#{@dir}/src")
    5.times { |i| File.write("#{@dir}/src/f#{i}.txt", "hello #{i}\n") }
  end

  def teardown = FileUtils.remove_entry(@dir)

  def test_runs_both_targets_and_reports_sizes
    plan = Rakpak::Plan.new(paths: ["#{@dir}/src"], outdir: @dir,
                            basename: "out", target: :both)
    job = Rakpak::Job.new(plan).start
    sleep 0.02 while job.running?

    assert_equal :done, job.state, job.error
    assert job.ok?
    plan.outputs.each { |o| assert File.size?(o), "#{o} is missing or empty" }
    assert_operator job.file_count, :>=, 5
  end

  def test_cancelling_removes_the_half_written_archive
    plan = Rakpak::Plan.new(paths: ["#{@dir}/src"], outdir: @dir,
                            basename: "part", target: :tar)
    job = Rakpak::Job.new(plan).start
    job.cancel
    sleep 0.02 while job.running?

    assert_equal :cancelled, job.state
    refute File.exist?(plan.output),
           "a truncated archive must not be left behind"
  end

def test_a_pre_existing_output_is_replaced_and_a_failed_replacement_is_not_left_behind
  plan = Rakpak::Plan.new(paths: ["#{@dir}/nope"], outdir: @dir,
                          basename: "keep", target: :tar)
  File.write(plan.output, "precious")
  job = Rakpak::Job.new(plan).start
  sleep 0.02 while job.running?

  assert_equal :failed, job.state
  # The confirm screen warned that the output would be overwritten, and
  # tar truncates it the moment it starts anyway. What must not remain is
  # a zero-byte husk pretending to be the old archive.
  refute File.exist?(plan.output),
         "a failed run must not leave a truncated output behind"
end

  def test_failure_is_surfaced_not_swallowed
    plan = Rakpak::Plan.new(paths: ["#{@dir}/does-not-exist"], outdir: @dir,
                            basename: "bad", target: :tar)
    job = Rakpak::Job.new(plan).start
    sleep 0.02 while job.running?

    assert_equal :failed, job.state
    refute_nil job.error
  end
end

class JobFailureTest < Minitest::Test
  # A plan whose second step cannot possibly run.
  class HalfFail < Rakpak::Plan
    def outputs = [output, "#{output}.second"]

    def steps
      [["tar", super.first[1], true, nil], ["second", ["rakpak-no-such-binary"], false, nil]]
    end
  end

  class AllFail < Rakpak::Plan
    def steps = [["tar", ["rakpak-no-such-binary"], false, nil]]
  end

  def setup
    @dir = Dir.mktmpdir("rakpak")
    FileUtils.mkdir_p("#{@dir}/src")
    File.write("#{@dir}/src/f.txt", "hello")
  end

  def teardown = FileUtils.remove_entry(@dir)

  def run_to_completion(job)
    job.start
    sleep 0.02 while job.running?
    job
  end

def test_a_finished_first_step_survives_a_failing_second_step
  plan = HalfFail.new(paths: ["#{@dir}/src"], outdir: @dir,
                      basename: "keep", target: :both)
  job = run_to_completion(Rakpak::Job.new(plan))

  assert_equal :failed, job.state
  assert File.size?(plan.output),
         "the first step completed; only the interrupted step's output is partial"
end

  def test_a_missing_binary_is_reported_not_blanked
    plan = AllFail.new(paths: ["#{@dir}/src"], outdir: @dir,
                       basename: "x", target: :tar)
    job = run_to_completion(Rakpak::Job.new(plan))

    assert_equal :failed, job.state
    assert_match(/no-such-binary/, job.error.to_s,
                 "the real diagnostic must not be replaced by an empty status")
  end

  def test_a_failed_spawn_does_not_leak_pipes
    skip "needs /proc" unless File.directory?("/proc/self/fd")
    before = Dir.children("/proc/self/fd").size
    3.times do
      plan = AllFail.new(paths: ["#{@dir}/src"], outdir: @dir,
                         basename: "x", target: :tar)
      run_to_completion(Rakpak::Job.new(plan))
    end
    assert_operator Dir.children("/proc/self/fd").size, :<=, before + 1
  end
end

class NonAsciiTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    FileUtils.mkdir_p("#{@dir}/src")
    File.write("#{@dir}/src/café-日本.txt", "x")
  end

  def teardown = FileUtils.remove_entry(@dir)

  def test_a_non_ascii_filename_does_not_break_the_frame
    plan = Rakpak::Plan.new(paths: ["#{@dir}/src"], outdir: @dir,
                            basename: "u", target: :tar)
    job = Rakpak::Job.new(plan).start
    sleep 0.02 while job.running?
    assert_equal :done, job.state, job.error

    screen = Rakpak::Screen.new(80, 10)
    job.tail(5).each_with_index { |l, i| screen.put(0, i, l) }
    screen.render # must not raise Encoding::CompatibilityError
    assert(job.tail(5).all? { |l| l.encoding == Encoding::UTF_8 && l.valid_encoding? })
  end

  def test_the_screen_refuses_raw_bytes_from_any_source
    screen = Rakpak::Screen.new(20, 2)
    screen.put(0, 0, "caf\xC3".dup.force_encoding(Encoding::ASCII_8BIT))
    screen.put(0, 1, "ok")
    screen.render
  end
end

class ShortTerminalTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    FileUtils.mkdir_p("#{@dir}/src")
    File.write("#{@dir}/src/f.txt", "x")
    @flushed = nil
    Rakpak::Term.singleton_class.send(:alias_method, :real_flush, :flush_frame)
    Rakpak::Term.define_singleton_method(:flush_frame) { |s| s }
  end

  def teardown
    Rakpak::Term.singleton_class.send(:alias_method, :flush_frame, :real_flush)
    FileUtils.remove_entry(@dir)
  end

  def test_job_view_survives_the_shortest_allowed_terminal
    [10, 11, 12, 24].each do |rows|
      plan = Rakpak::Plan.new(paths: ["#{@dir}/src"], outdir: @dir,
                              basename: "s", target: :both)
      app = Rakpak::App.new(@dir)
      app.instance_variable_set(:@screen, Rakpak::Screen.new(80, rows))
      app.instance_variable_set(:@mode, :job)
      app.instance_variable_set(:@focus_job, Rakpak::Job.new(plan))
      app.send(:draw) # used to raise ArgumentError: negative array size
    end
  end
end

class DirCacheTest < Minitest::Test
  def test_an_unreadable_directory_is_not_re_read_every_frame
    cache = Rakpak::DirCache.new
    assert_nil cache.list("/proc/1/root/nope")
    store = cache.instance_variable_get(:@cache)
    assert store.key?(["/proc/1/root/nope", false]),
           "a failed listing must be memoised, not retried on every frame"
  end
end

class QuitConfirmTest < Minitest::Test
  def test_b_does_not_quit_from_the_jobs_running_dialog
    m = Rakpak::ConfirmModal.new(title: "t", lines: [])
    assert_nil m.handle("b")
    assert_equal :done, m.handle(:enter)
  end

def test_b_does_not_start_the_job_from_the_confirm_screen
  m = Rakpak::ConfirmModal.new(title: "t", lines: [])
  assert_nil m.handle("b"), "b must never confirm a pack; it is too close to back"
  assert_nil m.result
  assert_equal :done, m.handle(:enter)
  assert_equal :run, m.result
end
end

class InputModalTest < Minitest::Test
  def test_editing_keys
    m = Rakpak::InputModal.new(title: "t", value: "hello")
    m.handle(:backspace)
    m.handle("y")
    assert_equal :done, m.handle(:enter)
    assert_equal "helly", m.result
  end

  def test_empty_input_is_not_accepted
    m = Rakpak::InputModal.new(title: "t", value: "")
    assert_nil m.handle(:enter)
  end

  def test_ctrl_w_deletes_a_word
    m = Rakpak::InputModal.new(title: "t", value: "one two")
    m.handle(:ctrl_w)
    m.handle(:enter)
    assert_equal "one", m.result
  end
end

class FormModalTest < Minitest::Test
  def rows(available)
    val = :a
    [Rakpak::FormModal::Row.new(kind: :choice, label: "m",
                                values: [["A", :a, available, "no A here"], ["B", :b, true, nil]],
                                get: -> { val }, set: ->(v) { val = v })]
  end

  def test_accept_is_blocked_while_a_choice_is_unavailable
    m = Rakpak::FormModal.new(title: "t", rows: rows(false))
    assert_nil m.handle(:enter)
    assert_includes m.footer_text, "no A here"
  end

  def test_accept_succeeds_once_valid
    m = Rakpak::FormModal.new(title: "t", rows: rows(false))
    m.handle("l") # cycle onto B
    assert_equal :done, m.handle(:enter)
  end
end

class ArgsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    FileUtils.mkdir_p("#{@dir}/docs")
    File.write("#{@dir}/docs/a.txt", "a")
  end

  def teardown = FileUtils.remove_entry(@dir)

  def test_no_arguments_start_in_the_home_folder
    o = Rakpak.parse([])
    assert_equal :browse, o.action
    assert_equal Dir.home, o.dir
    assert_empty o.pack
  end

  def test_a_folder_argument_is_expanded_and_used
    o = Rakpak.parse(["#{@dir}/docs/"])
    assert_equal "#{@dir}/docs", o.dir
    # macOS temp folders live behind a /private symlink, and "." resolves
    # to the real one.
    Dir.chdir(@dir) { assert_equal Dir.pwd, Rakpak.parse(["."]).dir }
  end

  def test_pack_opens_beside_the_target_with_it_queued
    o = Rakpak.parse(["-p", "#{@dir}/docs/"])
    assert_equal @dir, o.dir, "browser opens on the folder holding the target"
    assert_equal ["#{@dir}/docs"], o.pack
    assert_equal ["#{@dir}/docs", "#{@dir}/docs/a.txt"],
                 Rakpak.parse(["--pack", "#{@dir}/docs", "#{@dir}/docs/a.txt"]).pack
  end

  def test_help_and_version_and_bad_input
    assert_equal :help, Rakpak.parse(["--help"]).action
    assert_equal :version, Rakpak.parse(["-v"]).action
    assert_raises(ArgumentError) { Rakpak.parse(["-p"]) }
    assert_raises(ArgumentError) { Rakpak.parse(["-p", "#{@dir}/nope"]) }
    assert_raises(ArgumentError) { Rakpak.parse(["#{@dir}/docs/a.txt"]) }
    assert_raises(ArgumentError) { Rakpak.parse(["--bogus"]) }
    assert_raises(ArgumentError) { Rakpak.parse(["#{@dir}", "#{@dir}/docs"]) }
  end

  def test_pack_launch_opens_the_archive_prompt_over_the_right_folder
    app = Rakpak::App.new(@dir, pack: ["#{@dir}/docs"])
    browser = app.instance_variable_get(:@browser)
    assert_equal @dir, browser.cwd
    assert_equal "docs", browser.current.name, "cursor rests on the target"
    assert_equal ["#{@dir}/docs"], browser.tags.to_a
    modal = app.instance_variable_get(:@modal)
    assert_kind_of Rakpak::SelectModal, modal, "the first prompt is open before the first frame"
    plan = app.instance_variable_get(:@plan)
    assert_equal @dir, plan.outdir
    assert_equal "docs", app.send(:default_basename, plan.paths)
  end

  def test_pack_of_a_hidden_file_reveals_it
    File.write("#{@dir}/.secret", "s")
    app = Rakpak::App.new(@dir, pack: ["#{@dir}/.secret"])
    browser = app.instance_variable_get(:@browser)
    assert browser.show_hidden?
    assert_equal ".secret", browser.current.name
  end
end

class BasenameTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    FileUtils.mkdir_p("#{@dir}/my.project")
    File.write("#{@dir}/notes.txt", "n")
    File.write("#{@dir}/.bashrc", "b")
  end

  def teardown = FileUtils.remove_entry(@dir)

  def name_for(*paths)
    app = Rakpak::App.new(@dir)
    app.send(:default_basename, paths)
  end

  def test_folders_keep_their_dots_and_files_lose_their_extension
    assert_equal "my.project", name_for("#{@dir}/my.project")
    assert_equal "notes", name_for("#{@dir}/notes.txt")
    assert_equal ".bashrc", name_for("#{@dir}/.bashrc"), "a dotfile is not an empty name"
    assert_equal File.basename(@dir), name_for("#{@dir}/notes.txt", "#{@dir}/my.project")
  end
end

class TildeTest < Minitest::Test
  def test_only_a_real_home_prefix_is_shortened
    home = Dir.home
    assert_equal "~", Rakpak::Text.tilde(home)
    assert_equal "~/x/y", Rakpak::Text.tilde("#{home}/x/y")
    assert_equal "#{home}2/x", Rakpak::Text.tilde("#{home}2/x")
    assert_equal "/etc", Rakpak::Text.tilde("/etc")
  end
end

class PreviewTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    system("mkfifo", "#{@dir}/pipe")
    @b = Rakpak::Browser.new(@dir)
  end

  def teardown = FileUtils.remove_entry(@dir)

  def test_a_fifo_is_not_opened_for_reading
    skip "mkfifo unavailable" unless File.pipe?("#{@dir}/pipe")
    e = @b.entries.find { |x| x.name == "pipe" }
    done = false
    t = Thread.new { @b.send(:build_preview, e, 40, 5).tap { done = true } }
    t.join(2)
    assert done, "previewing a FIFO must not block waiting for a writer"
    assert_equal "not a regular file", t.value.first.first
  end
end

class CodecFormTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    File.write("#{@dir}/f", "x")
  end

  def teardown = FileUtils.remove_entry(@dir)

def test_both_sides_drive_the_same_form_and_reset_the_level_on_a_new_codec
  plan = Rakpak::Plan.new(paths: ["#{@dir}/f"], outdir: @dir, target: :both)
  plan.tar.codec = :zstd
  assert_equal :zstd, plan.tar_codec.id
  assert_equal 3, plan.tar_level
  plan.tar.level = 9
  assert_equal 9, plan.tar_level
  plan.compress.codec = :zip_store
  assert_equal :zip_store, plan.compressor.id
  assert_nil plan.comp_level
  assert_raises(ArgumentError) { plan.compress.codec = :nope }

  app = Rakpak::App.new(@dir)
  app.instance_variable_set(:@plan, plan)
  %i[both zip tar].each do |target|
    plan.target = target
    form = app.send(:options_modal)
    form.sync_rows if form.respond_to?(:sync_rows)
    assert_kind_of Rakpak::FormModal, form
  end
end
end

class ReviewFindingsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    FileUtils.mkdir_p("#{@dir}/src")
    5.times { |i| File.write("#{@dir}/src/f#{i}.txt", "hello #{i}\n") }
  end

  def teardown = FileUtils.remove_entry(@dir)

  def finish(job)
    job.start
    job.wait(10)
    job
  end

  def test_quitting_stops_running_jobs_and_removes_their_partial_output
    plan = Rakpak::Plan.new(paths: ["#{@dir}/src"], outdir: @dir, basename: "q", target: :tar)
    plan.tar_codec = Rakpak.tar_codec(:none)
    job = Rakpak::Job.new(plan)
    app = Rakpak::App.new(@dir)
    app.instance_variable_set(:@jobs, [job])
    job.start
    app.send(:stop_jobs)
    refute job.running?, "quit must wait for the cancel to land"
    assert_equal :cancelled, job.state
    refute File.exist?(plan.output)
  end

  def test_zip_replaces_an_existing_archive_instead_of_updating_it
    skip "zip not installed" unless Rakpak::Tools.available?("zip")
    plan = Rakpak::Plan.new(paths: ["#{@dir}/src"], outdir: @dir, basename: "z", target: :zip)
    finish(Rakpak::Job.new(plan))
    File.unlink("#{@dir}/src/f3.txt")
    finish(Rakpak::Job.new(plan))
    listing = `unzip -l #{plan.output} 2>/dev/null`
    listing = `zipinfo -1 #{plan.output} 2>/dev/null` if listing.empty?
    skip "no zip lister" if listing.empty?
    refute_match(/f3\.txt/, listing, "a deleted file must not survive into the new archive")
  end

  def test_a_junk_file_at_the_output_path_is_overwritten
    plan = Rakpak::Plan.new(paths: ["#{@dir}/src"], outdir: @dir, basename: "j", target: :tar)
    File.write(plan.output, "not a tarball")
    job = finish(Rakpak::Job.new(plan))
    assert_equal :done, job.state, job.error
    assert_operator File.size(plan.output), :>, 100
  end

  def test_cancel_before_the_first_spawn_runs_nothing
    plan = Rakpak::Plan.new(paths: ["#{@dir}/src"], outdir: @dir, basename: "c", target: :tar)
    job = Rakpak::Job.new(plan)
    job.cancel
    finish(job)
    assert_equal :cancelled, job.state
    assert_equal 0, job.file_count, "the step must not run to completion after a cancel"
    refute File.exist?(plan.output)
  end

def test_cancel_between_steps_keeps_the_finished_first_output
  slow = Class.new(Rakpak::Plan) do
    def outputs = [output, "#{output}.second"]
    def steps = [super.first, ["slow", ["sleep", "5"], false, nil]]
  end
  plan = slow.new(paths: ["#{@dir}/src"], outdir: @dir, basename: "b", target: :tar)
  job = Rakpak::Job.new(plan)
  # Cancel the instant the second step is announced: the gap after the
  # first has finished and before the second has spawned.
  job.define_singleton_method(:push) do |line|
    super(line)
    cancel if line.start_with?("▸ slow")
  end
  finish(job)
  assert_equal :cancelled, job.state
  assert File.size?(plan.output), "a completed earlier step's archive must survive"
  refute File.exist?("#{plan.output}.second")
end

  def test_non_verbose_steps_do_not_count_diagnostics_as_files
    plan = Rakpak::Plan.new(paths: ["#{@dir}/src"], outdir: @dir, basename: "v", target: :tar)
    plan.tar_flags.find { |f| f.id == :verbose }.on = false
    job = finish(Rakpak::Job.new(plan, total_files: 6))
    assert_equal :done, job.state, job.error
    assert_nil job.fraction, "no member listing means no honest fraction"
    assert_equal 0, job.file_count
  end

def test_a_signal_death_is_named
  plan = Rakpak::Plan.new(paths: ["#{@dir}/src"], outdir: @dir, basename: "s", target: :tar)
  plan.define_singleton_method(:steps) { [["tar", ["sh", "-c", "kill -TERM $$"], false, nil]] }
  job = finish(Rakpak::Job.new(plan))
  assert_equal :failed, job.state
  assert_match(/killed by SIGTERM/, job.error)
end
end

class SizerStalenessTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    FileUtils.mkdir_p("#{@dir}/big")
    File.write("#{@dir}/big/a", "x" * 100)
    @sizer = Rakpak::Sizer.new
    @b = Rakpak::Browser.new(@dir, sizer: @sizer)
  end

  def teardown = FileUtils.remove_entry(@dir)

  def settle(path)
    50.times do
      r = @sizer[path]
      return r if r

      sleep 0.02
    end
    flunk "sizer never reported #{path}"
  end

  def test_reload_remeasures_and_every_untag_path_forgets
    big = "#{@dir}/big"
    @b.tag(big)
    assert_equal 100, settle(big).bytes
    File.write("#{@dir}/big/b", "y" * 100)
    @b.refresh!
    assert_equal 200, settle(big).bytes, "ctrl-r must re-measure tagged folders"

    @b.clear_tags
    assert_nil @sizer[big]
    @b.tag(big)
    settle(big)
    @b.untag_all_here
    assert_nil @sizer[big]
    @b.replace_tags([big])
    @b.replace_tags([])
    assert_nil @sizer[big]
  end
end

class SmallFixesTest < Minitest::Test
  def test_control_characters_have_no_width_and_never_reach_the_frame
    t = Rakpak::Text
    assert_equal 0, t.gw("\x7F")
    assert_equal 0, t.gw("\u0085")
    assert_equal 0, t.gw("\u009B")
    assert_equal 1, t.gw("a")
    s = Rakpak::Screen.new(20, 1)
    s.put(0, 0, "a\x7Fb\u009Bc")
    refute_includes s.render, "\u009B"
    refute_includes s.render, "\x7F"
  end

  def test_missing_zstd_falls_back_to_a_real_compressor_not_none
    plan = Rakpak::Plan.new(paths: [Dir.pwd], outdir: Dir.pwd)
    fb = plan.tar_codec_fallback
    if Rakpak::TAR_CODECS.any? { |c| c.bin && c.available? }
      refute_equal :none, fb.id
    else
      assert_equal :none, fb.id
    end
  end

  def test_a_stray_g_does_not_swallow_the_next_key
    dir = Dir.mktmpdir("rakpak")
    b = Rakpak::Browser.new(dir)
    b.handle("g")
    assert_equal :quit, b.handle("q")
    b.handle("g")
    assert_equal :archive, b.handle("p")
  ensure
    FileUtils.remove_entry(dir)
  end

  def test_in_session_argument_errors_are_not_reported_as_usage_errors
    stub = Class.new do
      def initialize(*, **) = nil
      def run = raise(ArgumentError, "negative array size")
    end
    real = Rakpak::App
    Rakpak.send(:remove_const, :App)
    Rakpak.const_set(:App, stub)
    $stdout.define_singleton_method(:tty?) { true }
    $stdin.define_singleton_method(:tty?) { true }
    assert_raises(ArgumentError) { Rakpak.start([]) }
  ensure
    Rakpak.send(:remove_const, :App)
    Rakpak.const_set(:App, real)
    $stdout.singleton_class.send(:remove_method, :tty?)
    $stdin.singleton_class.send(:remove_method, :tty?)
  end

  def test_alt_keys_carry_their_character
    r, w = IO.pipe
    w.write("x")
    w.close
    saved = $stdin
    $stdin = r
    assert_equal :alt_x, Rakpak::Term.read_escape
  ensure
    $stdin = saved
  end

  def test_typed_extensions_are_replaced_case_insensitively
    plan = Rakpak::Plan.new(paths: [Dir.pwd], outdir: Dir.pwd, basename: "x")
    plan.tar_codec = Rakpak.tar_codec(:gzip)
    %w[x.TAR.ZST x.tgz x.zip x.tar].each do |name|
      plan.basename = name
      assert_equal "x.tar.gz", File.basename(plan.output), name
    end
  end
end

class DefaultsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    File.write("#{@dir}/f", "x")
  end

  def teardown = FileUtils.remove_entry(@dir)

  def test_both_and_gzip_are_the_defaults
    plan = Rakpak::Plan.new(paths: ["#{@dir}/f"], outdir: @dir)
    assert_equal :both, plan.target
    if Rakpak.tar_codec(:gzip).available?
      assert_equal :gzip, plan.tar_codec.id
      assert_equal 6, plan.tar_level
      assert_equal ".tar.gz", plan.ext
    end
    assert_equal 1, plan.outputs.size, "both means one compressed tarball, not two files"
  end

  def test_both_is_offered_first_and_preselected
    app = Rakpak::App.new(@dir)
    app.instance_variable_set(:@plan, Rakpak::Plan.new(paths: ["#{@dir}/f"], outdir: @dir))
    modal = app.send(:target_modal)
    items = modal.instance_variable_get(:@items)
    assert_equal %i[both tar zip], items.map(&:value)
    if items.first.enabled
      assert_equal 0, modal.instance_variable_get(:@index)
      modal.handle(:enter)
      assert_equal :both, modal.result
    end
  end
end

class OutputShapeTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    FileUtils.mkdir_p("#{@dir}/folder")
    File.write("#{@dir}/folder/a.txt", "hello\n" * 100)
    File.write("#{@dir}/one.txt", "hello\n" * 100)
  end

  def teardown = FileUtils.remove_entry(@dir)

  def run_plan(plan)
    job = Rakpak::Job.new(plan).start
    job.wait(10)
    job
  end

  def test_compressed_tarball_is_one_file_with_the_codec_extension
    skip "gzip missing" unless Rakpak.tar_codec(:gzip).available?
    plan = Rakpak::Plan.new(paths: ["#{@dir}/folder"], outdir: @dir, basename: "f", target: :both)
    assert_equal ".tar.gz", plan.ext
    assert_includes plan.tar_argv, "--use-compress-program"
    job = run_plan(plan)
    assert_equal :done, job.state, job.error
    assert_equal ["f.tar.gz"], Dir.children(@dir).grep(/\Af\./)
    assert system("tar", "-tzf", plan.output, out: File::NULL, err: File::NULL)
  end

  def test_plain_tarball_is_uncompressed
    plan = Rakpak::Plan.new(paths: ["#{@dir}/folder"], outdir: @dir, basename: "p", target: :tar)
    assert_equal ".tar", plan.ext
    refute_includes plan.tar_argv, "--use-compress-program"
    job = run_plan(plan)
    assert_equal :done, job.state, job.error
    assert File.exist?("#{@dir}/p.tar")
  end

  def test_zip_target_makes_a_zip
    skip "zip missing" unless Rakpak::Tools.available?("zip")
    plan = Rakpak::Plan.new(paths: ["#{@dir}/folder"], outdir: @dir, basename: "z", target: :zip)
    assert_equal :zip, plan.compressor.id
    assert_equal ".zip", plan.ext
    job = run_plan(plan)
    assert_equal :done, job.state, job.error
    assert File.size?("#{@dir}/z.zip")
  end

  def test_a_lone_file_can_be_gzipped_on_its_own
    skip "gzip missing" unless Rakpak.tar_codec(:gzip).available?
    plan = Rakpak::Plan.new(paths: ["#{@dir}/one.txt"], outdir: @dir, basename: "one.txt", target: :zip)
    plan.compress.codec = :gzip
    assert plan.single_compress?
    assert_equal ".gz", plan.ext
    assert_equal "one.txt.gz", File.basename(plan.output)
    label, argv, verbose, stdout = plan.steps.first
    assert_equal "gzip", label
    assert_equal plan.output, stdout
    refute verbose
    assert_match(/ > /, plan.preview.first[1])
    job = run_plan(plan)
    assert_equal :done, job.state, job.error
    assert system("gzip", "-t", plan.output, out: File::NULL, err: File::NULL)
    assert_operator File.size(plan.output), :<, File.size("#{@dir}/one.txt")
    refute_includes argv, "one.txt.gz"
  end

  def test_gzipping_a_folder_is_refused_with_a_reason
    plan = Rakpak::Plan.new(paths: ["#{@dir}/folder"], outdir: @dir, basename: "x", target: :zip)
    plan.compressor = Rakpak.compressor(:gzip)
    assert(plan.problems.any? { |m| m.include?("one file only") })
  end

  def test_target_labels_are_the_proper_names_with_compression_first
    app = Rakpak::App.new(@dir)
    app.instance_variable_set(:@plan, Rakpak::Plan.new(paths: ["#{@dir}/folder"], outdir: @dir))
    items = app.send(:target_modal).instance_variable_get(:@items)
    assert_equal ["compressed tarball", "plain tarball", "zip archive"], items.map(&:label)
    assert_equal %i[both tar zip], items.map(&:value)
  end

  def test_default_name_keeps_the_full_filename_for_a_bare_compression
    app = Rakpak::App.new(@dir)
    plan = Rakpak::Plan.new(paths: ["#{@dir}/one.txt"], outdir: @dir, target: :zip)
    plan.compressor = Rakpak.compressor(:gzip)
    app.instance_variable_set(:@plan, plan)
    assert_equal "one.txt", app.send(:default_basename, plan.paths)
    plan.target = :both
    assert_equal "one", app.send(:default_basename, plan.paths)
  end
end

class WhereStepTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    FileUtils.mkdir_p("#{@dir}/docs")
    File.write("#{@dir}/docs/a.txt", "a")
    @app = Rakpak::App.new(@dir, pack: ["#{@dir}/docs"])
  end

  def teardown = FileUtils.remove_entry(@dir)

  def modal = @app.instance_variable_get(:@modal)
  def plan = @app.instance_variable_get(:@plan)
  def key(k) = @app.send(:modal_key, k)
  def type(text) = text.each_char { |c| key(c) }
  def plain(m) = (s = Rakpak::Screen.new(120, 30); m.draw(s); s.render.gsub(/\e\[[0-9;]*[A-Za-z]/, ""))

  def to_where_step
    key(:enter) # target: compressed tarball
    assert_kind_of Rakpak::DynamicForm, modal
    key(:enter) # options
    assert_kind_of Rakpak::WhereModal, modal
  end

  def test_the_prompt_shows_numbered_choices_with_full_paths_and_a_field
    to_where_step
    text = plain(modal)
    assert_includes text, "1. This directory"
    # A long temp path is clipped from the left to fit the panel, so check
    # the tail; a tilde-shortened path would not have it.
    assert_includes text, @dir[-30..], "the real path, not a tilde-shortened one"
    assert_includes text, "2. Home directory"
    assert_includes text, Dir.home
    assert_includes text, "3. Specify"
  end

  def test_this_directory_is_the_default_and_home_is_one_down
    to_where_step
    key(:enter)
    assert_equal @dir, plan.outdir
    assert_kind_of Rakpak::InputModal, modal, "next comes the name"

    key(:esc)
    assert_kind_of Rakpak::WhereModal, modal
    key("j")
    key(:enter)
    assert_equal Dir.home, plan.outdir
  end

  def test_digits_pick_directly
    to_where_step
    key("2")
    assert_equal Dir.home, plan.outdir
  end

  def test_typing_jumps_to_specify_and_accepts_tilde_env_and_absolute_paths
    to_where_step
    type("$HOME")
    key(:enter)
    assert_equal Dir.home, plan.outdir

    key(:esc)
    assert_kind_of Rakpak::WhereModal, modal
    key("3")
    type("~")
    key(:enter)
    assert_equal Dir.home, plan.outdir

    key(:esc)
    key("3")
    key(:ctrl_u) # the field remembers what was typed before; clear it
    type(@dir)
    key(:enter)
    assert_equal @dir, plan.outdir
  end

  def test_a_bad_folder_is_refused_in_place
    to_where_step
    field = modal
    type("#{@dir}/nope")
    key(:enter)
    assert_same field, modal, "the prompt stays up"
    assert_match(/not a folder/, field.footer_text)
  end

  def test_specify_with_nothing_typed_is_refused
    to_where_step
    key("j")
    key("j")
    key(:enter)
    assert_kind_of Rakpak::WhereModal, modal
    assert_match(/type a folder/i, modal.footer_text)
  end
end

class ExpandDirTest < Minitest::Test
  def test_forms_people_type
    home = Dir.home
    assert_equal home, Rakpak.expand_dir("~")
    assert_equal home, Rakpak.expand_dir("~/")
    assert_equal "#{home}/x", Rakpak.expand_dir("~/x")
    assert_equal home, Rakpak.expand_dir("$HOME")
    assert_equal "#{home}/x", Rakpak.expand_dir("${HOME}/x")
    assert_equal "/", Rakpak.expand_dir("/")
    assert_equal "/etc", Rakpak.expand_dir("/etc/")
    assert_equal home, Rakpak.expand_dir("  ~  ")
    assert_equal home, Rakpak.expand_dir("")
  end
end

class WrapAroundTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    %w[a b c].each { |n| File.write("#{@dir}/#{n}", n) }
    @b = Rakpak::Browser.new(@dir)
  end

  def teardown = FileUtils.remove_entry(@dir)

  def test_single_steps_wrap_but_page_moves_do_not
    assert_equal 0, @b.index
    @b.handle("k")
    assert_equal 2, @b.index, "up from the top lands on the last entry"
    @b.handle(:down)
    assert_equal 0, @b.index, "down from the bottom lands on the first"
    @b.handle(:up)
    @b.handle(:ctrl_d)
    assert_equal 2, @b.index, "a page down stops at the end"
    @b.handle("G")
    @b.handle("j")
    assert_equal 0, @b.index
  end
end

class JobViewKeysTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    File.write("#{@dir}/f", "x")
    @app = Rakpak::App.new(@dir)
    plan = Rakpak::Plan.new(paths: ["#{@dir}/f"], outdir: @dir, basename: "j", target: :tar)
    @job = Rakpak::Job.new(plan).start
    @job.wait(10)
    @app.instance_variable_set(:@jobs, [@job])
    @app.instance_variable_set(:@focus_job, @job)
    @app.instance_variable_set(:@mode, :job)
  end

  def teardown = FileUtils.remove_entry(@dir)

  def mode = @app.instance_variable_get(:@mode)

  def test_q_quits_and_backspace_goes_back_once_the_job_is_done
    assert_equal :done, @job.state, @job.error
    @app.send(:job_key, :backspace)
    assert_equal :browse, mode, "backspace returns to the browser"

    @app.instance_variable_set(:@mode, :job)
    @app.send(:job_key, "q")
    assert @app.instance_variable_get(:@quit), "q quits the program, as the footer says"
  end
end

class QueuePaneTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    FileUtils.mkdir_p("#{@dir}/Downloads")
    FileUtils.mkdir_p("#{@dir}/Projects")
    File.write("#{@dir}/Downloads/report.pdf", "r" * 2048)
    File.write("#{@dir}/Projects/notes.txt", "n")
    @sizer = Rakpak::Sizer.new
    @b = Rakpak::Browser.new(@dir, sizer: @sizer)
  end

  def teardown = FileUtils.remove_entry(@dir)

  def plain(screen) = screen.render.gsub(/\e\[[0-9;]*[A-Za-z]/, "")

  def test_the_queue_pane_is_on_by_default_at_the_far_left_and_t_hides_it
    assert @b.show_queue?, "shown until someone turns it off"
    assert_equal %i[queue parent current preview], @b.layout(120).map { |p| p[:kind] }
    assert_equal 0, @b.layout(120).first[:x], "the queue sits at the far left"
    assert_nil @b.handle("t")
    refute @b.show_queue?
    assert_equal %i[parent current preview], @b.layout(120).map { |p| p[:kind] }
    @b.handle("t")
    assert @b.show_queue?
  end

  def test_the_pane_lists_every_queued_path_with_its_size_and_a_total
    @b.tag("#{@dir}/Downloads/report.pdf")
    @b.tag("#{@dir}/Projects")
    sleep 0.02 until @sizer["#{@dir}/Downloads/report.pdf"] && @sizer["#{@dir}/Projects"]
    screen = Rakpak::Screen.new(140, 24)
    @b.draw(screen, nil)
    text = plain(screen)
    assert_includes text, "QUEUE"
    assert_includes text, "report.pdf"
    assert_includes text, "2 tagged"
    assert_includes text, "Downloads"
    assert_includes text, "Projects"
    assert_includes text, "2.0K"
  end

  def test_an_empty_queue_says_so
    screen = Rakpak::Screen.new(140, 24)
    @b.draw(screen, nil)
    assert_includes plain(screen), "nothing tagged"
  end
end

class OutputNameTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    FileUtils.mkdir_p("#{@dir}/docs")
    @app = Rakpak::App.new(@dir, pack: ["#{@dir}/docs"])
  end

  def teardown = FileUtils.remove_entry(@dir)

  def modal = @app.instance_variable_get(:@modal)
  def key(k) = @app.send(:modal_key, k)

  def test_the_name_cannot_leave_the_chosen_folder
    key(:enter) # target
    key(:enter) # options
    key(:enter) # where: this directory
    assert_equal "output name", modal.instance_variable_get(:@title)
    field = modal
    key(:ctrl_u)
    "../../etc/evil".each_char { |c| key(c) }
    key(:enter)
    assert_same field, modal, "a name with a slash is refused in place"
    assert_match(/no slashes/, field.footer_text)
    key(:ctrl_u)
    "safe".each_char { |c| key(c) }
    key(:enter)
    assert_kind_of Rakpak::ConfirmModal, modal
    assert_equal "#{@dir}/safe.tar.gz", @app.instance_variable_get(:@plan).output
  end
end

class ReportSanitiserTest < Minitest::Test
  def test_the_exit_summary_never_prints_escape_sequences
    base = Dir.mktmpdir("rakpak")
    evil = File.join(base, "out\e]0;pwned\a")
    Dir.mkdir(evil)
    File.write("#{base}/f", "x")
    plan = Rakpak::Plan.new(paths: ["#{base}/f"], outdir: evil, basename: "a", target: :tar)
    job = Rakpak::Job.new(plan).start
    job.wait(10)
    assert_equal :done, job.state, job.error
    app = Rakpak::App.new(base)
    app.instance_variable_set(:@jobs, [job])
    out = StringIO.new
    saved = $stdout
    $stdout = out
    app.send(:report)
    $stdout = saved
    refute_includes out.string, "\e", "a folder name must not reach the shell as an escape sequence"
    assert_includes out.string, "a.tar"
  ensure
    $stdout = saved if saved
    FileUtils.remove_entry(base) if base
  end
end

class SecondReviewTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
  end

  def teardown = FileUtils.remove_entry(@dir)

  def with_stdin(bytes)
    r, w = IO.pipe
    w.write(bytes.b)
    w.close
    saved = $stdin
    $stdin = r
    yield
  ensure
    $stdin = saved
  end

  def test_a_stray_byte_is_dropped_and_a_split_utf8_char_is_reassembled
    with_stdin("\xC3") { assert_nil Rakpak::Term.read_key }
    with_stdin("\xC3\xA9") do
      k = Rakpak::Term.read_key
      assert_equal "é", k
      assert k.valid_encoding?
    end
    with_stdin("\xFF") { assert_nil Rakpak::Term.read_key }
  end

  def test_a_browsed_folder_with_a_dollar_sign_is_used_as_is
    odd = File.join(@dir, "proj$HOME")
    Dir.mkdir(odd)
    File.write("#{odd}/f", "x")
    app = Rakpak::App.new(odd, pack: ["#{odd}/f"])
    key = ->(k) { app.send(:modal_key, k) }
    key.call(:enter)
    key.call(:enter)
    key.call(:enter) # 1. This directory
    assert_equal odd, app.instance_variable_get(:@plan).outdir
  end

  def test_a_filename_that_is_not_utf8_still_lists_and_filters
    begin
      File.write(File.join(@dir, "caf\xE9.txt".b), "x")
    rescue Errno::EILSEQ, Errno::EINVAL
      skip "this filesystem refuses names that are not valid UTF-8"
    end
    File.write("#{@dir}/plain.txt", "y")
    b = Rakpak::Browser.new(@dir)
    assert_equal 2, b.entries.size, "one bad name must not blank the whole folder"
    b.handle("/")
    "plain".each_char { |c| b.handle(c) }
    assert_equal ["plain.txt"], b.entries.map(&:name)
  end

  def test_overwriting_half_a_wide_glyph_keeps_the_row_the_right_width
    s = Rakpak::Screen.new(20, 1)
    s.put(0, 0, "日本語")
    s.put(4, 0, " ") # lands on the second half of 本
    row = s.render.gsub(/\e\[[0-9;]*[A-Za-z]/, "").split("\r\n").first
    assert_equal 20, Rakpak::Text.width(row), "the row must still be exactly 20 columns"
    s.fill(1, 0, 1, 1, "x")
    row = s.render.gsub(/\e\[[0-9;]*[A-Za-z]/, "").split("\r\n").first
    assert_equal 20, Rakpak::Text.width(row)
  end

  def test_the_input_cursor_sits_after_wide_text
    m = Rakpak::InputModal.new(title: "t", value: "日本語")
    s = Rakpak::Screen.new(60, 8)
    m.draw(s)
    row = s.render.gsub(/\e\[[0-9;]*[A-Za-z]/, "").split("\r\n").find { |l| l.include?("日本語") }
    assert_equal 60, Rakpak::Text.width(row)
  end

  def test_a_lone_tar_gzipped_on_its_own_keeps_its_name
    File.write("#{@dir}/backup.tar", "t")
    plan = Rakpak::Plan.new(paths: ["#{@dir}/backup.tar"], outdir: @dir, basename: "backup.tar", target: :zip)
    plan.compressor = Rakpak.compressor(:gzip)
    assert_equal "backup.tar.gz", File.basename(plan.output)
    plan.target = :both
    plan.basename = "backup.tar"
    assert_equal "backup.tar.gz", File.basename(plan.output), "for a tarball the typed .tar is still folded"
  end

  def test_a_stale_walk_cannot_overwrite_a_fresh_request
    sizer = Rakpak::Sizer.new
    slow = true
    sizer.define_singleton_method(:measure) do |path|
      sleep 0.15 if slow
      Rakpak::Sizer::Result.new(slow ? 1 : 2, 1, false)
    end
    sizer.request("x")
    sleep 0.02
    sizer.invalidate!
    slow = false
    sizer.request("x")
    sleep 0.3
    assert_equal 2, sizer["x"].bytes, "the answer must come from the walk started by the current request"
  end

  def test_prune_handles_root_and_sorts_by_components
    assert_equal ["/"], Rakpak::Plan.prune(["/", "/etc"])
    FileUtils.mkdir_p("#{@dir}/a/b")
    FileUtils.mkdir_p("#{@dir}/a-x")
    got = Rakpak::Plan.prune(["#{@dir}/a-x", "#{@dir}/a/b", "#{@dir}/a"])
    assert_equal ["#{@dir}/a", "#{@dir}/a-x"], got, "a/b is inside a even though a-x sorts between them"
    many = (1..3000).map { |i| "#{@dir}/f#{i}" }
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Rakpak::Plan.prune(many)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t, :<, 0.5
  end

  def test_root_selection_warns_about_archiving_itself
    plan = Rakpak::Plan.new(paths: ["/"], outdir: @dir, basename: "all", target: :tar)
    assert(plan.warnings.any? { |w| w.include?("archive itself") })
  end

  def test_select_notes_survive_a_wide_terminal
    items = [Rakpak::SelectModal::Item.new(label: "tarball", value: :t, enabled: false,
                                           why: "tar not installed", blurb: "")]
    m = Rakpak::SelectModal.new(title: "t", items: items)
    s = Rakpak::Screen.new(200, 20)
    m.draw(s)
    assert_includes s.render.gsub(/\e\[[0-9;]*[A-Za-z]/, ""), "tar not installed"
  end

  def test_tagging_after_a_cursor_only_pack_measures_again
    FileUtils.mkdir_p("#{@dir}/x")
    sizer = Rakpak::Sizer.new
    b = Rakpak::Browser.new(@dir, sizer: sizer)
    sizer.request("#{@dir}/x")
    sleep 0.02 until sizer["#{@dir}/x"]
    File.write("#{@dir}/x/big", "z" * 500)
    b.tag("#{@dir}/x")
    sleep 0.02 until sizer["#{@dir}/x"]
    assert_equal 500, sizer["#{@dir}/x"].bytes
  end
end

class GemspecTest < Minitest::Test
  def test_the_gem_ships_the_program_and_nothing_else
    spec = Gem::Specification.load(File.expand_path("../rakpak.gemspec", __dir__))
    assert_equal "rakpak", spec.name
    assert_equal Rakpak::VERSION, spec.version.to_s
    assert_equal ["rakpak"], spec.executables
    assert_includes spec.files, "bin/rakpak"
    assert_includes spec.files, "lib/rakpak.rb"
    assert_includes spec.files, "lib/rakpak/app.rb"
    assert_includes spec.files, "README.md"
    refute(spec.files.any? { |f| f.start_with?("test/") || f == "install.sh" })
    assert_equal ">= 3.0", spec.required_ruby_version.to_s
  end
end

class UnpackFormatTest < Minitest::Test
  U = Rakpak::Unpack

  def test_a_tarball_extension_wins_over_the_bare_compressor
    assert_equal :tar, U.format("a.tar.gz").kind
    assert_equal :tar, U.format("a.tgz").kind
    assert_equal :single, U.format("a.gz").kind
  end

  def test_every_shape_rakpak_can_write_can_be_read_back
    exts = %w[.tar .tar.gz .tar.zst .tar.xz .tar.bz2 .tar.lz4 .tar.br .zip
              .gz .zst .xz .bz2 .lz4 .br .tgz .tbz2 .txz .tzst]
    exts.each { |e| refute_nil U.format("a#{e}"), "#{e} is not recognised" }
    assert_equal :zip, U.format("a.zip").kind
    assert_equal :tar, U.format("a.tar").kind
  end

  def test_anything_else_is_not_an_archive
    assert_nil U.format("notes.txt")
    assert_nil U.format("gz")
    refute U.archive?("notes.txt")
    assert U.archive?("notes.tar.gz")
  end

  def test_detection_ignores_case
    assert_equal :tar, U.format("A.TAR.GZ").kind
  end

  def test_the_destination_folder_is_named_for_the_archive
    assert_equal "notes", U.default_subdir("/x/notes.tar.gz")
    assert_equal "notes", U.default_subdir("/x/notes.tgz")
    assert_equal "site", U.default_subdir("/x/site.zip")
  end

  # notes.txt.gz holds exactly one file, so it lands beside you as notes.txt
  # rather than inside a pointless notes.txt/ folder.
  def test_a_lone_compressed_file_needs_no_folder
    assert_nil U.default_subdir("/x/notes.txt.gz")
    assert_equal "notes.txt", U.member_name("/x/notes.txt.gz")
  end
end

class UnpackPlanTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    File.write("#{@dir}/a.tar.gz", "not really")
  end

  def teardown = FileUtils.remove_entry(@dir)

  def unpack(name, dest: "#{@dir}/out")
    Rakpak::Unpack.new(archive: "#{@dir}/#{name}", dest: dest)
  end

  # Tools memoizes the flavor it detects; pin it for one block, then put back
  # whatever the real tar was.
  def with_tar_flavor(flavor)
    had = Rakpak::Tools.instance_variable_defined?(:@tar_flavor)
    real = Rakpak::Tools.instance_variable_get(:@tar_flavor)
    Rakpak::Tools.instance_variable_set(:@tar_flavor, flavor)
    yield
  ensure
    if had then Rakpak::Tools.instance_variable_set(:@tar_flavor, real)
    else Rakpak::Tools.remove_instance_variable(:@tar_flavor)
    end
  end

  # GNU tar runs "<program> -d" itself to read an archive, so the program
  # must be the bare binary. brotli refuses a second command flag.
  def test_gnu_tar_is_left_to_add_its_own_decompress_flag
    with_tar_flavor(:gnu) do
      _, argv, = unpack("a.tar.br").steps.first
      assert_equal "brotli", argv[argv.index("--use-compress-program") + 1]
    end
  end

  # bsdtar runs the program exactly as given, so without -d the compressor
  # would compress the archive a second time.
  def test_bsdtar_is_told_to_decompress
    with_tar_flavor(:bsd) do
      _, argv, = unpack("a.tar.br").steps.first
      assert_equal "brotli -d", argv[argv.index("--use-compress-program") + 1]
    end
  end

  def test_a_tarball_is_extracted_with_the_codec_as_a_compress_program
    u = unpack("a.tar.lz4")
    label, argv, verbose, stdout = u.steps.first
    assert_equal "tar", label
    assert_includes argv, "--use-compress-program"
    assert_match(/\Alz4( -d)?\z/, argv[argv.index("--use-compress-program") + 1])
    assert_includes argv, "#{@dir}/a.tar.lz4"
    assert_equal ["-C", "#{@dir}/out"], argv.last(2)
    assert verbose, "tar -v drives the progress readout"
    assert_nil stdout
  end

  def test_a_plain_tar_needs_no_compress_program
    refute_includes unpack("a.tar").steps.first[1], "--use-compress-program"
  end

  def test_a_zip_is_extracted_by_unzip_into_the_destination
    _, argv, = unpack("a.zip").steps.first
    assert_equal ["unzip", "-o", "#{@dir}/a.zip", "-d", "#{@dir}/out"], argv
  end

  # gzip writes to stdout, which Job redirects into a scratch file beside the
  # real one; the rename happens only once gzip has exited cleanly.
  def test_a_lone_compressed_file_is_written_through_a_scratch_file
    u = unpack("notes.txt.gz", dest: @dir)
    label, argv, _, stdout = u.steps.first
    assert_equal "gzip", label
    assert_equal ["gzip", "-dc", "#{@dir}/notes.txt.gz"], argv
    assert_equal "#{@dir}/.notes.txt.part", stdout
    assert_equal ["#{@dir}/notes.txt"], u.outputs, "the real output is still the plain name"
    assert_match(/ > /, u.preview.first[1])
  end

  # Job chdirs into base and, for a real archive, must never treat the
  # destination folder as something to unlink first.
  def test_the_destination_is_the_base_and_is_never_clobbered
    u = unpack("a.tar.gz")
    assert_equal "#{@dir}/out", u.base
    assert_equal ["#{@dir}/out"], u.outputs
    refute u.clobbers_output?
    assert unpack("notes.txt.gz", dest: @dir).clobbers_output?,
           "a recovered file is a plain output and may be replaced"
  end

  def test_prepare_creates_the_destination
    u = unpack("a.tar.gz", dest: "#{@dir}/deep/nested")
    refute File.directory?("#{@dir}/deep/nested")
    u.prepare
    assert File.directory?("#{@dir}/deep/nested")
  end

  def test_a_missing_archive_or_unknown_shape_is_a_problem
    assert(unpack("nope.tar.gz").problems.any? { |m| m.include?("no such file") })
    File.write("#{@dir}/b.txt", "x")
    assert(unpack("b.txt").problems.any? { |m| m.include?("not an archive") })
  end

  def test_a_missing_tool_is_named
    u = unpack("a.tar.gz")
    def u.missing?(bin) = bin == "gzip"
    assert(u.problems.any? { |m| m.include?("gzip not installed") })
  end

  # Something that is not a folder standing where the destination must go
  # should be named on the confirm screen, not raised out of mkdir mid-run.
  def test_a_file_in_the_way_of_the_destination_is_a_problem
    File.write("#{@dir}/out", "precious")
    assert(unpack("a.tar.gz").problems.any? { |m| m.include?("not a folder") },
           unpack("a.tar.gz").problems.inspect)
  end

  def test_an_existing_destination_with_files_in_it_warns
    assert_empty unpack("a.tar.gz").warnings
    FileUtils.mkdir_p("#{@dir}/out")
    assert_empty unpack("a.tar.gz").warnings, "an empty folder is nothing to say"
    File.write("#{@dir}/out/there", "x")
    assert(unpack("a.tar.gz").warnings.any? { |m| m.include?("already has files") })
  end

  def test_argv_is_never_shell_interpreted
    File.write("#{@dir}/we ird;name.tar", "x")
    assert_includes unpack("we ird;name.tar").steps.first[1], "#{@dir}/we ird;name.tar"
  end
end

class UnpackJobTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    FileUtils.mkdir_p("#{@dir}/src/deep")
    File.write("#{@dir}/src/top.txt", "top\n")
    File.write("#{@dir}/src/deep/inner.txt", "inner\n")
  end

  def teardown = FileUtils.remove_entry(@dir)

  def run_job(plan)
    job = Rakpak::Job.new(plan).start
    job.wait(20)
    job
  end

  def pack(target: :both, basename: "arc")
    plan = Rakpak::Plan.new(paths: ["#{@dir}/src"], outdir: @dir,
                            basename: basename, target: target)
    assert_equal :done, run_job(plan).state
    plan.output
  end

  def unpack(archive, dest)
    Rakpak::Unpack.new(archive: archive, dest: dest)
  end

  def test_a_tarball_round_trips_back_to_the_same_tree
    archive = pack
    job = run_job(unpack(archive, "#{@dir}/back"))

    assert_equal :done, job.state, job.error
    assert_equal "top\n", File.read("#{@dir}/back/src/top.txt")
    assert_equal "inner\n", File.read("#{@dir}/back/src/deep/inner.txt")
    assert_operator job.file_count, :>, 0, "tar -v feeds the progress readout"
  end

  def test_a_zip_round_trips
    skip "zip missing" unless Rakpak::Tools.available?("zip")
    skip "unzip missing" unless Rakpak::Tools.available?("unzip")
    job = run_job(unpack(pack(target: :zip, basename: "z"), "#{@dir}/back"))

    assert_equal :done, job.state, job.error
    assert_equal "inner\n", File.read("#{@dir}/back/src/deep/inner.txt")
  end

  def test_a_lone_compressed_file_round_trips
    skip "gzip missing" unless Rakpak.tar_codec(:gzip).available?
    plan = Rakpak::Plan.new(paths: ["#{@dir}/src/top.txt"], outdir: @dir,
                            basename: "top.txt", target: :zip)
    plan.compress.codec = :gzip
    assert_equal :done, run_job(plan).state

    dest = "#{@dir}/back"
    u = unpack(plan.output, dest)
    assert_equal :done, run_job(u).state, "gzip -dc must land in the destination"
    assert_equal "top\n", File.read("#{dest}/top.txt")
  end

  # The output of an extraction is a folder. Job unlinks a pack output before
  # each step; doing that here would delete the destination.
  def test_the_destination_folder_and_its_contents_survive
    archive = pack
    FileUtils.mkdir_p("#{@dir}/back")
    File.write("#{@dir}/back/keepme", "precious")
    job = run_job(unpack(archive, "#{@dir}/back"))

    assert_equal :done, job.state, job.error
    assert_equal "precious", File.read("#{@dir}/back/keepme")
    assert_equal "top\n", File.read("#{@dir}/back/src/top.txt")
  end

  def test_a_failed_extraction_leaves_what_it_already_wrote
    File.write("#{@dir}/broken.tar.gz", "this is not a tarball")
    FileUtils.mkdir_p("#{@dir}/back")
    File.write("#{@dir}/back/keepme", "precious")
    job = run_job(unpack("#{@dir}/broken.tar.gz", "#{@dir}/back"))

    assert_equal :failed, job.state
    refute_nil job.error
    assert File.directory?("#{@dir}/back"), "the destination is not ours to remove"
    assert_equal "precious", File.read("#{@dir}/back/keepme")
  end

  # Every codec rakpak can write, it must be able to read back.
  def test_every_codec_round_trips
    Rakpak::TAR_CODECS.each do |codec|
      next unless codec.bin && codec.available?

      plan = Rakpak::Plan.new(paths: ["#{@dir}/src"], outdir: @dir,
                              basename: "r-#{codec.id}", target: :both)
      plan.tar_codec = codec
      plan.tar_level = codec.default
      assert_equal :done, run_job(plan).state, "packing #{codec.id}"

      dest = "#{@dir}/back-#{codec.id}"
      job = run_job(unpack(plan.output, dest))
      assert_equal :done, job.state, "#{codec.id}: #{job.error}"
      assert_equal "inner\n", File.read("#{dest}/src/deep/inner.txt"), codec.id.to_s
    end
  end

  def test_the_destination_is_created_on_the_way_in
    archive = pack
    job = run_job(unpack(archive, "#{@dir}/deep/nested/back"))

    assert_equal :done, job.state, job.error
    assert_equal "top\n", File.read("#{@dir}/deep/nested/back/src/top.txt")
  end
end

class UnpackWizardTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    FileUtils.mkdir_p("#{@dir}/src")
    File.write("#{@dir}/src/f.txt", "hello\n")
    plan = Rakpak::Plan.new(paths: ["#{@dir}/src"], outdir: @dir,
                            basename: "arc", target: :both)
    job = Rakpak::Job.new(plan).start
    job.wait(20)
    @archive = plan.output
    File.write("#{@dir}/plain.txt", "nope")
  end

  def teardown = FileUtils.remove_entry(@dir)

  # The hint bar truncates rather than wraps, so a key added to it can push
  # another one off the end without anyone noticing.
  def test_the_hint_bar_shows_every_key_it_lists
    screen = Rakpak::Screen.new(80, 20)
    Rakpak::Browser.new(@dir).draw(screen, nil)
    foot = screen.render.lines.last.gsub(/\e\[[0-9;]*m/, "")
    Rakpak::Browser::HINTS.each do |key, label|
      assert_includes foot, "#{key} #{label}", "dropped off the end at 80 columns"
    end
    assert_includes foot, ". hidden"
    assert_includes foot, "u unpack"
  end

  def test_u_requests_unpacking
    b = Rakpak::Browser.new(@dir)
    assert_equal :unpack, b.handle("u")
  end

  # The tag set drives packing; unpacking is about the one archive you are
  # looking at, so it follows the cursor.
  def test_u_follows_the_cursor_not_the_tags
    app = app_on("arc.tar.gz")
    app.instance_variable_get(:@browser).tag("#{@dir}/plain.txt")
    app.send(:dispatch, "u")
    assert_equal @archive, app.instance_variable_get(:@plan).archive
  end

  def app_on(name)
    app = Rakpak::App.new(@dir)
    browser = app.instance_variable_get(:@browser)
    browser.jump_to("#{@dir}/#{name}")
    app
  end

  def test_a_file_that_is_not_an_archive_says_so
    app = app_on("plain.txt")
    app.send(:dispatch, "u")
    assert_nil app.instance_variable_get(:@plan)
    modal = app.instance_variable_get(:@modal)
    assert_kind_of Rakpak::MessageModal, modal
  end

  def test_the_first_prompt_asks_where_and_the_second_names_the_folder
    app = app_on("arc.tar.gz")
    app.send(:dispatch, "u")
    assert_kind_of Rakpak::WhereModal, app.instance_variable_get(:@modal)

    app.send(:dispatch, :enter) # this folder
    name = app.instance_variable_get(:@modal)
    assert_kind_of Rakpak::InputModal, name
    assert_equal "arc", name.text, "the folder is named for the archive"

    app.send(:dispatch, :enter)
    assert_kind_of Rakpak::ConfirmModal, app.instance_variable_get(:@modal)
    assert_equal "#{@dir}/arc", app.instance_variable_get(:@plan).dest
  end

  # "." is how you say "no subfolder, put it right here".
  def test_a_dot_means_straight_into_the_chosen_folder
    app = app_on("arc.tar.gz")
    app.send(:dispatch, "u")
    app.send(:dispatch, :enter)
    modal = app.instance_variable_get(:@modal)
    modal.handle(:ctrl_w)
    modal.handle(".")
    app.send(:dispatch, :enter)
    assert_equal @dir, app.instance_variable_get(:@plan).dest
  end

  def test_escaping_out_of_the_prompts_leaves_no_plan
    app = app_on("arc.tar.gz")
    app.send(:dispatch, "u")
    app.send(:dispatch, :esc)
    assert_nil app.instance_variable_get(:@modal)
    assert_nil app.instance_variable_get(:@plan)
  end

  # The whole interactive path, from the key to files on disk.
  def test_the_prompts_end_in_a_real_extraction
    app = app_on("arc.tar.gz")
    app.send(:dispatch, "u")
    app.send(:dispatch, :enter) # unpack into this folder
    app.send(:dispatch, :enter) # keep the folder named for the archive
    app.send(:dispatch, :enter) # confirm, and go

    job = app.instance_variable_get(:@jobs).first
    refute_nil job, "enter on the confirm screen starts the job"
    job.wait(20)
    assert_equal :done, job.state, job.error
    assert_equal "hello\n", File.read("#{@dir}/arc/src/f.txt")
    assert_equal "unpacked into arc/", job.plan.outcome
  end

  def test_the_help_lists_the_unpack_key
    app = Rakpak::App.new(@dir)
    app.send(:open_help)
    lines = app.instance_variable_get(:@modal).instance_variable_get(:@lines)
    assert(lines.any? { |l| l.match?(/\Au\s+unpack/) }, lines.inspect)
  end

  # Job asks the plan how many members to expect; an archive is not listed
  # first, so an unpack simply counts up.
  def test_an_unpack_reports_no_member_total
    u = Rakpak::Unpack.new(archive: @archive, dest: "#{@dir}/out")
    assert_nil u.total_members(Rakpak::Sizer.new)
  end
end

class UnpackReportingTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    FileUtils.mkdir_p("#{@dir}/src")
    File.write("#{@dir}/src/f.txt", "hello\n")
    @pack = Rakpak::Plan.new(paths: ["#{@dir}/src"], outdir: @dir,
                             basename: "arc", target: :both)
    Rakpak::Job.new(@pack).start.wait(20)
  end

  def teardown = FileUtils.remove_entry(@dir)

  def unpack(dest = "#{@dir}/back")
    Rakpak::Unpack.new(archive: @pack.output, dest: dest)
  end

  def test_the_job_view_says_which_way_the_work_is_going
    assert_equal "archiving", @pack.gerund
    assert_equal "unpacking", unpack.gerund
  end

  def test_the_job_title_follows_the_plan
    app = Rakpak::App.new(@dir)
    assert_equal "unpacking", app.send(:job_title, Rakpak::Job.new(unpack), :running)
    assert_equal "archiving", app.send(:job_title, Rakpak::Job.new(@pack), :running)
    assert_equal "finished", app.send(:job_title, Rakpak::Job.new(unpack), :done)
  end

  def test_a_finished_pack_is_reported_by_name_and_size
    assert_match(/\Aarc\.tar\.gz \d/, @pack.outcome)
  end

  def test_a_finished_unpack_names_the_folder_it_filled
    u = unpack
    Rakpak::Job.new(u).start.wait(20)
    assert_equal "unpacked into back/", u.outcome
  end

  def test_a_recovered_lone_file_is_reported_by_name_and_size
    plan = Rakpak::Plan.new(paths: ["#{@dir}/src/f.txt"], outdir: @dir,
                            basename: "f.txt", target: :zip)
    plan.compress.codec = :gzip
    Rakpak::Job.new(plan).start.wait(20)
    u = Rakpak::Unpack.new(archive: plan.output, dest: "#{@dir}/back")
    Rakpak::Job.new(u).start.wait(20)
    assert_match(%r{\Af\.txt \d}, u.outcome)
  end

  # A folder's own inode size means nothing; the status line must not show it.
  def test_a_destination_folder_has_no_byte_count_to_show
    u = unpack
    job = Rakpak::Job.new(u).start
    job.wait(20)
    assert_nil job.output_size
  end

  def test_what_landed_is_printed_after_the_tui_goes
    app = Rakpak::App.new(@dir)
    u = unpack
    job = Rakpak::Job.new(u).start
    job.wait(20)
    app.instance_variable_get(:@jobs) << job
    out, = capture_io { app.send(:report) }
    assert_includes out, "#{@dir}/back"
    assert_includes out, "unpacked"
  end
end

class UnpackCliTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rakpak")
    FileUtils.mkdir_p("#{@dir}/src/deep")
    File.write("#{@dir}/src/top.txt", "top\n")
    File.write("#{@dir}/src/deep/inner.txt", "inner\n")
    plan = Rakpak::Plan.new(paths: ["#{@dir}/src"], outdir: @dir,
                            basename: "arc", target: :both)
    Rakpak::Job.new(plan).start.wait(20)
    @archive = plan.output
    File.write("#{@dir}/plain.txt", "nope")
  end

  def teardown = FileUtils.remove_entry(@dir)

  def test_d_asks_for_an_unpack_and_keeps_the_paths
    o = Rakpak.parse(["-d", @archive])
    assert_equal :unpack, o.action
    assert_equal [@archive], o.unpack
    assert_equal [@archive], Rakpak.parse(["--depack", @archive]).unpack
  end

  def test_several_archives_are_taken_in_turn
    FileUtils.cp(@archive, "#{@dir}/two.tar.gz")
    assert_equal [@archive, "#{@dir}/two.tar.gz"],
                 Rakpak.parse(["-d", @archive, "#{@dir}/two.tar.gz"]).unpack
  end

  def test_bad_input_is_refused_before_anything_runs
    assert_raises(ArgumentError) { Rakpak.parse(["-d"]) }
    assert_raises(ArgumentError) { Rakpak.parse(["-d", "#{@dir}/nope.tar.gz"]) }
    assert_raises(ArgumentError) { Rakpak.parse(["-d", "#{@dir}/plain.txt"]) }
    assert_raises(ArgumentError) { Rakpak.parse(["-d", @archive, "-p", "#{@dir}/src"]) }
    assert_raises(ArgumentError) { Rakpak.parse(["-d", "#{@dir}/src"]) }
  end

  # "right there, like tar": the folder you are standing in.
  def test_it_unpacks_into_the_current_folder_and_needs_no_terminal
    work = "#{@dir}/work"
    FileUtils.mkdir_p(work)
    out, status = Dir.chdir(work) { capture_status(["-d", @archive]) }

    assert_equal 0, status
    assert_equal "top\n", File.read("#{work}/arc/src/top.txt")
    assert_equal "inner\n", File.read("#{work}/arc/src/deep/inner.txt")
    assert_includes out, "arc"
  end

  def test_a_lone_compressed_file_lands_beside_you_with_no_folder
    skip "gzip missing" unless Rakpak.tar_codec(:gzip).available?
    plan = Rakpak::Plan.new(paths: ["#{@dir}/src/top.txt"], outdir: @dir,
                            basename: "top.txt", target: :zip)
    plan.compress.codec = :gzip
    Rakpak::Job.new(plan).start.wait(20)
    work = "#{@dir}/work2"
    FileUtils.mkdir_p(work)
    _, status = Dir.chdir(work) { capture_status(["-d", plan.output]) }

    assert_equal 0, status
    assert_equal "top\n", File.read("#{work}/top.txt")
    refute File.directory?("#{work}/top.txt.gz")
  end

  def test_every_archive_is_attempted_and_a_failure_sets_the_status
    File.write("#{@dir}/broken.tar.gz", "not a tarball at all")
    work = "#{@dir}/work3"
    FileUtils.mkdir_p(work)
    status = nil
    _, err = capture_io do
      Dir.chdir(work) { status = Rakpak.start(["-d", "#{@dir}/broken.tar.gz", @archive]) }
    end

    assert_equal 1, status, "a failure must be visible to the shell"
    refute_empty err
    assert_equal "top\n", File.read("#{work}/arc/src/top.txt"),
                 "the good archive is still unpacked"
  end

  def test_the_usage_text_mentions_unpacking
    assert_match(/-d/, Rakpak::USAGE)
    assert_match(/unpack/i, Rakpak::USAGE)
  end

  def capture_status(argv)
    status = nil
    out, = capture_io { status = Rakpak.start(argv) }
    [out, status]
  end
end

# Findings from review of the depacker. Each one reproduced a real defect.
class UnpackSafetyTest < Minitest::Test
  U = Rakpak::Unpack

  def setup
    @dir = Dir.mktmpdir("rakpak")
    FileUtils.mkdir_p("#{@dir}/src")
    File.write("#{@dir}/src/f.txt", "hello\n")
    plan = Rakpak::Plan.new(paths: ["#{@dir}/src"], outdir: @dir,
                            basename: "arc", target: :both)
    Rakpak::Job.new(plan).start.wait(20)
    @archive = plan.output
  end

  def teardown
    File.chmod(0o700, "#{@dir}/wo") if File.directory?("#{@dir}/wo")
    FileUtils.remove_entry(@dir)
  end

  def run_job(plan)
    job = Rakpak::Job.new(plan).start
    job.wait(20)
    job
  end

  # The output is opened for writing before the compressor has proved it can
  # read the archive, so it must not be the user's file.
  def test_a_failed_single_unpack_leaves_the_original_alone
    File.write("#{@dir}/notes.txt", "PRECIOUS")
    File.write("#{@dir}/notes.txt.gz", "not gzip data")
    job = run_job(U.new(archive: "#{@dir}/notes.txt.gz", dest: @dir))

    assert_equal :failed, job.state
    assert_equal "PRECIOUS", File.read("#{@dir}/notes.txt")
    assert_empty Dir.children(@dir).grep(/part/), "no scratch file left behind"
  end

  def test_a_successful_single_unpack_still_replaces_the_file
    skip "gzip missing" unless Rakpak.tar_codec(:gzip).available?
    File.write("#{@dir}/one.txt", "fresh\n")
    system("gzip", "-k", "#{@dir}/one.txt")
    File.write("#{@dir}/one.txt", "stale")
    job = run_job(U.new(archive: "#{@dir}/one.txt.gz", dest: @dir))

    assert_equal :done, job.state, job.error
    assert_equal "fresh\n", File.read("#{@dir}/one.txt")
    assert_empty Dir.children(@dir).grep(/part/)
  end

  # A folder can be writable but not listable. warnings must not raise out of
  # the render loop, and problems should name it.
  def test_a_destination_that_cannot_be_listed_is_reported_not_raised
    skip "root ignores permissions" if Process.uid.zero?

    FileUtils.mkdir_p("#{@dir}/wo")
    File.chmod(0o300, "#{@dir}/wo")
    u = U.new(archive: @archive, dest: "#{@dir}/wo")
    assert_empty u.warnings, "warnings must never raise"
    assert(u.problems.any? { |m| m.include?("not readable") }, u.problems.inspect)
  end

  # strip_ext can yield "." or "..", which File.join then resolves upwards.
  def test_a_dotted_archive_name_cannot_walk_out_of_the_destination
    refute_equal "..", U.default_subdir("/x/...tar")
    refute_equal ".", U.default_subdir("/x/..tar.gz")
    ["/x/...tar", "/x/..tar.gz", "/x/....zip"].each do |p|
      sub = U.default_subdir(p)
      next if sub.nil?

      dest = File.expand_path(File.join("/x", sub))
      assert dest.start_with?("/x/"), "#{p} escaped to #{dest}"
    end
  end

  def test_a_directory_named_like_an_archive_is_not_offered
    FileUtils.mkdir_p("#{@dir}/site.zip")
    app = Rakpak::App.new(@dir)
    app.instance_variable_get(:@browser).jump_to("#{@dir}/site.zip")
    app.send(:dispatch, "u")

    assert_nil app.instance_variable_get(:@plan)
    assert_kind_of Rakpak::MessageModal, app.instance_variable_get(:@modal)
  end

  # README says a lone compressed file skips the folder entirely.
  def test_a_lone_compressed_file_skips_the_folder_prompt
    skip "gzip missing" unless Rakpak.tar_codec(:gzip).available?
    File.write("#{@dir}/one.txt", "x\n")
    system("gzip", "#{@dir}/one.txt")
    app = Rakpak::App.new(@dir)
    app.instance_variable_get(:@browser).jump_to("#{@dir}/one.txt.gz")
    app.send(:dispatch, "u")
    app.send(:dispatch, :enter) # this folder

    assert_kind_of Rakpak::ConfirmModal, app.instance_variable_get(:@modal),
                   "no folder-name prompt for a single file"
    assert_equal @dir, app.instance_variable_get(:@plan).dest
  end

  def test_a_failed_unpack_does_not_leave_an_empty_folder_behind
    File.write("#{@dir}/broken.tar.gz", "not a tarball")
    job = run_job(U.new(archive: "#{@dir}/broken.tar.gz", dest: "#{@dir}/gone"))

    assert_equal :failed, job.state
    refute File.exist?("#{@dir}/gone"), "an empty folder we made is ours to remove"
  end

  # A tar that cannot pipe through a compressor should say so up front.
  def test_a_tar_that_cannot_pipe_is_refused_with_a_reason
    u = U.new(archive: @archive, dest: "#{@dir}/out")
    def u.tar_pipes? = false
    assert(u.problems.any? { |m| m.include?("cannot") }, u.problems.inspect)
  end

  def test_the_job_view_shows_no_byte_count_for_a_destination_folder
    job = run_job(U.new(archive: @archive, dest: "#{@dir}/back"))
    app = Rakpak::App.new(@dir)
    screen = Rakpak::Screen.new(90, 20)
    app.instance_variable_set(:@screen, screen)
    app.send(:draw_job, job)
    text = screen.render.gsub(/\e\[[0-9;]*m/, "")

    refute_match(/back\s+\d+(\.\d+)?[BKMG]/, text, "a folder has no size worth printing")
  end

  def test_app_can_be_required_on_its_own
    lib = File.expand_path("../lib", __dir__)
    assert system(RbConfig.ruby, "-I#{lib}", "-e", 'require "rakpak/app"; Rakpak::Unpack',
                  out: File::NULL, err: File::NULL),
           "app.rb must require what it uses"
  end

  # Children run in their own process group so a cancel takes the whole
  # pipeline, which also means the terminal's ctrl-c never reaches them.
  # Without the interrupt handler, tar carries on after rakpak has gone.
  def test_an_interrupted_headless_run_takes_the_extractor_with_it
    ENV["RK_TEST_SLEEP"] = "30"
    plan = Struct.new(:base, :outputs) do
      def steps = [["sleep", ["sleep", ENV.fetch("RK_TEST_SLEEP")], false, nil]]
      def prepare; end
      def commit; end
      def rollback; end
      def clobbers_output? = false
      def gerund = "sleeping"
      def report_note = "-"
    end.new(@dir, [@dir])

    kids = -> { `pgrep -P #{Process.pid}`.split.map(&:strip) }
    main = Thread.current
    Thread.new { sleep 0.4; main.raise(Interrupt) }
    running = nil
    Thread.new { sleep 0.2; running = kids.call }

    assert_raises(Interrupt) { capture_io { Rakpak.run_headless(plan, StringIO.new) } }
    sleep 0.4

    refute_empty running.to_a, "the step should have been running to begin with"
    assert_empty kids.call, "the extractor outlived rakpak"
  ensure
    ENV.delete("RK_TEST_SLEEP")
  end

  # An archive can leave a symlink in the destination pointing anywhere it
  # likes. The scratch file's name is derived from the archive, so it can be
  # aimed at in advance; opening it must never follow the link.
  def test_a_planted_symlink_in_the_destination_is_not_written_through
    skip "gzip missing" unless Rakpak.tar_codec(:gzip).available?
    File.write("#{@dir}/notes", "payload\n")
    system("gzip", "#{@dir}/notes")
    outside = "#{@dir}/OUTSIDE"
    File.symlink(outside, "#{@dir}/.notes.part") # dangling, so File.exist? is false

    job = run_job(U.new(archive: "#{@dir}/notes.gz", dest: @dir))

    refute File.exist?(outside), "wrote through a planted symlink to #{outside}"
    assert_equal :done, job.state, job.error
    assert_equal "payload\n", File.read("#{@dir}/notes")
  end

  def test_a_planted_symlink_onto_an_existing_file_is_not_written_through
    skip "gzip missing" unless Rakpak.tar_codec(:gzip).available?
    File.write("#{@dir}/notes", "payload\n")
    system("gzip", "#{@dir}/notes")
    victim = "#{@dir}/VICTIM"
    File.write(victim, "do not touch")
    File.symlink(victim, "#{@dir}/.notes.part")

    run_job(U.new(archive: "#{@dir}/notes.gz", dest: @dir))

    assert_equal "do not touch", File.read(victim)
  end

  # The same open-without-checking sat in the packing path before the unpack
  # feature existed, so the fix belongs in Job and is checked from both sides.
  def test_a_symlinked_pack_output_is_replaced_not_followed
    skip "gzip missing" unless Rakpak.tar_codec(:gzip).available?
    File.write("#{@dir}/one.txt", "hello\n")
    outside = "#{@dir}/OUTSIDE_PACK"
    plan = Rakpak::Plan.new(paths: ["#{@dir}/one.txt"], outdir: @dir,
                            basename: "one.txt", target: :zip)
    plan.compress.codec = :gzip
    File.symlink(outside, plan.output)

    run_job(plan)

    refute File.exist?(outside), "packing wrote through a symlinked output"
  end

  def test_a_headless_failure_says_what_the_tool_said
    File.write("#{@dir}/broken.tar.gz", "not a tarball")
    _, err = capture_io do
      Dir.chdir(@dir) { Rakpak.start(["-d", "#{@dir}/broken.tar.gz"]) }
    end
    assert_match(/gzip|not in gzip format|unexpected/i, err,
                 "the tool's own diagnostic is the useful part")
  end
end
