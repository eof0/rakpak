# frozen_string_literal: true

module Rakpak
  class Entry
    attr_reader :path, :name

    def initialize(path, name = nil)
      @path = path
      @name = name || File.basename(path)
    end

    def stat
      return @stat if defined?(@stat)

      @stat = begin
        File.lstat(@path)
      rescue StandardError
        nil
      end
    end

    def target_stat
      return @target_stat if defined?(@target_stat)

      @target_stat = begin
        File.stat(@path)
      rescue StandardError
        nil
      end
    end

    def symlink? = stat&.symlink? ? true : false
    def dir? = (symlink? ? target_stat : stat)&.directory? ? true : false
    def exec? = !dir? && (stat&.mode.to_i & 0o111).positive?
    def size = stat&.size
    def mtime = stat&.mtime

    def readable?
      return @readable if defined?(@readable)

      @readable = File.readable?(@path)
    end

    def link_target
      return nil unless symlink?

      @link_target ||= begin
        File.readlink(@path)
      rescue StandardError
        "?"
      end
    end

    def display
      dir? ? "#{@name}/" : @name
    end

    def style
      return Theme::LINK if symlink?
      return Theme::DIR if dir?
      return Theme::EXEC if exec?

      Theme::NORMAL
    end

    # Scrub invalid UTF-8 first, or downcase raises.
    def fold
      @fold ||= (@name.valid_encoding? ? @name : @name.scrub("?")).downcase
    end

    def sort_key
      [dir? ? 0 : 1, fold, @name]
    end
  end
end
