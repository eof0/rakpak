# frozen_string_literal: true

require_relative "entry"

module Rakpak
  class DirCache
    MAX_ENTRIES = 20_000

    def initialize
      @cache = {}
    end

    def invalidate!
      @cache.clear
    end

    def list(path, hidden: false)
      key = [path, hidden]
      # Cache failures too, or an EACCES parent is re-walked every frame.
      return @cache[key] if @cache.key?(key)

      @cache[key] = read(path, hidden)
    end

    private

    def read(path, hidden)
      names = Dir.children(path)
      names.reject! { |n| n.start_with?(".") } unless hidden
      names = names.first(MAX_ENTRIES)
      names.map { |n| Entry.new(File.join(path, n), n) }.sort_by(&:sort_key)
    rescue StandardError
      nil
    end
  end
end
