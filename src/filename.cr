# ActiveStorage::Filename — port of the gem's app/models filename
# value object (oracle: fn_* cases, activestorage 8.1.4).

module ActiveStorage
  class Filename
    getter raw : String

    def initialize(@raw : String)
    end

    # 8.1 semantics captured by the oracle: spaces are preserved, path
    # separators are not allowed, surrounding whitespace is stripped.
    def sanitized : String
      @raw.strip.tr("/\\", "--")
    end

    def base : String
      s = sanitized
      idx = s.rindex('.')
      idx && idx > 0 ? s[0...idx] : s
    end

    def extension : String
      s = sanitized
      idx = s.rindex('.')
      idx && idx > 0 ? s[(idx + 1)..] : ""
    end

    def to_s : String
      @raw
    end
  end
end
