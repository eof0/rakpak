# frozen_string_literal: true

module Rakpak
  module Text
    WIDE = [
      0x1100..0x115F, 0x2E80..0x303E, 0x3041..0x33FF, 0x3400..0x4DBF,
      0x4E00..0x9FFF, 0xA000..0xA4CF, 0xAC00..0xD7A3, 0xF900..0xFAFF,
      0xFE10..0xFE19, 0xFE30..0xFE6F, 0xFF00..0xFF60, 0xFFE0..0xFFE6,
      0x1F300..0x1F64F, 0x1F900..0x1F9FF, 0x20000..0x2FFFD
    ].freeze

    ZERO = [0x0300..0x036F, 0x200B..0x200F, 0xFE00..0xFE0F, 0xFEFF..0xFEFF].freeze

    module_function

    def gw(cluster)
      cp = cluster.ord
      return 1 if cp >= 0x20 && cp < 0x7F
      # C0, DEL and C1: a UTF-8 terminal executes U+009B as CSI.
      return 0 if cp < 0x20 || cp == 0x7F || (cp >= 0x80 && cp <= 0x9F)
      return 0 if ZERO.any? { |r| r.cover?(cp) }
      return 2 if WIDE.any? { |r| r.cover?(cp) }

      1
    rescue StandardError
      1
    end

    def width(str)
      w = 0
      str.each_grapheme_cluster { |g| w += gw(g) }
      w
    end

    def fit(str, max)
      return "" if max <= 0
      return str if width(str) <= max

      out = +""
      used = 0
      str.each_grapheme_cluster do |g|
        cw = gw(g)
        break if used + cw > max - 1

        out << g
        used += cw
      end
      out << "…"
    end

    def fit_left(str, max)
      return "" if max <= 0
      return str if width(str) <= max

      clusters = str.grapheme_clusters
      out = []
      used = 0
      clusters.reverse_each do |g|
        cw = gw(g)
        break if used + cw > max - 1

        out.unshift(g)
        used += cw
      end
      "…#{out.join}"
    end

    def pad(str, max)
      w = width(str)
      w >= max ? str : str + (" " * (max - w))
    end

    def wrap(str, max, indent = 0)
      return [str] if max <= indent + 4 || width(str) <= max

      lead = str[/\A[ \t]*/]
      pad = " " * indent
      out = []
      line = +""
      words = str[lead.length..].to_s.split(" ").flat_map do |word|
        limit = max - indent
        next word if width(word) <= limit || limit < 8

        word.grapheme_clusters.each_slice(limit).map(&:join)
      end
      words.each do |word|
        candidate = line.empty? ? word : "#{line} #{word}"
        if width(out.empty? ? lead + candidate : pad + candidate) <= max
          line = candidate
        else
          out << (out.empty? ? lead + line : pad + line)
          line = word
        end
      end
      out << (out.empty? ? lead + line : pad + line) unless line.empty?
      out
    end

    def tilde(path)
      home = Dir.home
      return path if home.nil? || home.empty? || home == "/"
      return "~" if path == home

      path.start_with?("#{home}/") ? "~#{path[home.length..]}" : path
    end

    # Control and C1 bytes could be executed as escape sequences.
    def plain(str)
      str.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?").gsub(/[\u0000-\u001f\u007f-\u009f]/, "?")
    end

    HUMAN = %w[B K M G T P].freeze

    def bytes(n)
      return "-" if n.nil?

      f = n.to_f
      i = 0
      while f >= 1024 && i < HUMAN.size - 1
        f /= 1024
        i += 1
      end
      i.zero? ? "#{n}B" : format("%.1f%s", f, HUMAN[i])
    end

    def duration(secs)
      s = secs.to_i
      return format("%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) if s >= 3600

      format("%d:%02d", s / 60, s % 60)
    end
  end
end
