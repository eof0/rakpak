# frozen_string_literal: true

require "io/console"

module Rakpak
  module Term
    ARROWS = { "A" => :up, "B" => :down, "C" => :right, "D" => :left,
               "H" => :home, "F" => :end }.freeze

    TILDE = { "1" => :home, "3" => :delete, "4" => :end,
              "5" => :pgup, "6" => :pgdn, "7" => :home, "8" => :end }.freeze

    class << self
      attr_accessor :resized
    end
    self.resized = false

    module_function

    def size
      h, w = $stdout.winsize
      [w.to_i.positive? ? w : 80, h.to_i.positive? ? h : 24]
    rescue StandardError
      [80, 24]
    end

    def start
      @stty = `stty -g 2>/dev/null`.chomp
      $stdin.raw!
      $stdout.write("\e[?1049h\e[?25l\e[2J")
      $stdout.flush
      trap("WINCH") { Term.resized = true }
    end

    def stop
      $stdout.write("\e[?25h\e[?1049l")
      $stdout.flush
      if @stty && !@stty.empty?
        system("stty", @stty, out: File::NULL, err: File::NULL)
      else
        begin
          $stdin.cooked!
        rescue StandardError
          nil
        end
      end
    end

    def flush_frame(str)
      $stdout.write(str)
      $stdout.flush
    end

    # Returns a key symbol, a printable String, or nil on timeout.
    def wait_key(timeout = nil)
      return nil unless IO.select([$stdin], nil, nil, timeout)

      read_key
    end

    def read_key
      c = getc_raw
      return nil if c.nil?

      c = complete_utf8(c)
      return nil if c.nil?

      case c
      when "\e"  then read_escape
      when "\r", "\n" then :enter
      when "\t"  then :tab
      when "\x7f", "\b" then :backspace
      when " "   then :space
      when "\x00".."\x1f" then :"ctrl_#{(c.ord + 96).chr}"
      else c
      end
    end

    # C locale getc yields single bytes; gather the sequence and drop it if still invalid.
    def complete_utf8(c)
      s = c.dup.force_encoding(Encoding::UTF_8)
      return s if s.valid_encoding?

      lead = s.getbyte(0)
      need = if lead.between?(0xC2, 0xDF) then 1
             elsif lead.between?(0xE0, 0xEF) then 2
             elsif lead.between?(0xF0, 0xF4) then 3
             else 0
             end
      need.times do
        more = getc_raw(ESC_WINDOW)
        break if more.nil?

        s = (s.b + more.b).force_encoding(Encoding::UTF_8)
      end
      s.valid_encoding? ? s : nil
    end

    def getc_raw(timeout = nil)
      return nil if timeout && !IO.select([$stdin], nil, nil, timeout)

      $stdin.getc
    rescue IOError, Errno::EINTR
      nil
    end

    # Escape sequences can split across reads on slow links; only a real Esc pays this wait.
    ESC_WINDOW = 0.05

    def read_escape
      seq = +""
      12.times do
        ch = getc_raw(ESC_WINDOW)
        break if ch.nil?

        seq << ch
        break if seq.match?(/\A\[[0-9;]*[A-Za-z~]\z/) || seq.match?(/\AO[A-Za-z]\z/)
      end
      return :esc if seq.empty?

      body = seq[1..] || ""
      if seq.start_with?("O")
        ARROWS[body] || :esc
      elsif seq.start_with?("[")
        if (m = body.match(/\A([0-9;]*)([A-Za-z~])\z/))
          num, fin = m[1], m[2]
          return ARROWS[fin] if ARROWS.key?(fin)
          return TILDE[num.split(";").first.to_s] || :esc if fin == "~"

          :esc
        else
          :esc
        end
      else
        :"alt_#{seq}"
      end
    end
  end
end
