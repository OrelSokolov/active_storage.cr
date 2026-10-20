# Port of ActiveStorage::Analyzer (activestorage 8.1.4): analyzer.rb,
# null_analyzer.rb, image_analyzer.rb (+ image_analyzer/vips.rb and
# image_magick.rb), video_analyzer.rb, audio_analyzer.rb, plus the
# engine's default analyzers list (engine.rb:
# config.active_storage.analyzers).
#
# Oracle: oracle/cases_analyzer.rb → oracle/expected_analyzer.yml
# (blob metadata JSON as stored by the gem, byte-for-byte).
#
# Deviations from the gem (documented):
#   * download_blob_to_tempfile writes a real temp file and yields its
#     PATH (the shard's transformers work on paths, not Ruby File
#     objects); the file is unlinked afterwards.
#   * Analyzers log-and-swallow library errors → {} exactly like the
#     gem, but there is no ActiveStorage.logger — messages are lost.
#   * ActiveStorage::AnalyzeJob lives in the opt-in src/analyze_job.cr
#     (active_job_cr dependency); Blob#analyze_later performs inline
#     unless it has been wired (see that file).
#   * The gem auto-analyzes via Attachment after_create_commit
#     (attachment.rb: analyze_blob_later); the port does not hook
#     attach — apps call blob.analyze! (or wire the job and call
#     analyze_later) themselves.
#   * The ImageMagick analyzer shells out to `identify -format
#     "%[orientation]"` directly: image_processing.cr's MiniMagick
#     exposes dimensions but not the orientation string.

module ActiveStorage
  class Analyzer
    # Metadata value union — what analyzers may return and what the
    # blob metadata JSON round-trips (int/float/bool/string/int-array/
    # string-hash; the gem's tags hash values are stringified).
    alias Value = Int64 | Float64 | Bool | String | Array(Int64) | Hash(String, String)

    attr_reader blob : Blob

    # Implement in a concrete subclass: true when the analyzer can
    # extract metadata from this blob.
    def self.accept?(blob : Blob) : Bool
      false
    end

    # Whether analysis should be enqueued in a job or performed inline.
    def self.analyze_later? : Bool
      true
    end

    def initialize(@blob : Blob)
    end

    # Override in a concrete subclass: a Hash of metadata.
    def metadata : Hash(String, Value)
      raise NotImplementedError.new("#{self.class}#metadata")
    end

    # Downloads the blob to a temp file on disk and yields its path
    # (the gem's blob.open(tmpdir:) yields an open tempfile).
    protected def download_blob_to_tempfile(&block : String -> U) : U forall U
      path = File.join(Dir.tempdir, "as_analyzer_#{Random::Secure.hex(8)}")
      File.write(path, @blob.download)
      begin
        yield path
      ensure
        File.delete(path) rescue nil
      end
    end

    # The blob metadata column as a Hash (the gem: store :metadata,
    # coder: JSON — nil column reads as {}).
    def self.parse_metadata(raw : String?) : Hash(String, Value)
      return {} of String => Value if raw.to_s.strip.empty?
      hash = {} of String => Value
      JSON.parse(raw.not_nil!).as_h.each do |key, value|
        hash[key] = from_json_any(value)
      end
      hash
    rescue JSON::ParseException
      {} of String => Value
    end

    # JSON-serializes metadata preserving insertion order (Ruby Hash
    # → JSON.generate): {"width":3840,"height":2160,"analyzed":true}.
    def self.metadata_json(metadata : Hash(String, Value)) : String
      String.build do |io|
        io << "{"
        first = true
        metadata.each do |key, value|
          io << "," unless first
          first = false
          key.to_json(io)
          io << ":"
          case value
          when Int64, String then value.to_json(io)
          when Float64       then value.to_json(io)
          when Bool          then value.to_json(io)
          when Array(Int64)  then value.to_json(io)
          when Hash(String, String)
            io << "{"
            vfirst = true
            value.each do |k, v|
              io << "," unless vfirst
              vfirst = false
              k.to_json(io)
              io << ":"
              v.to_json(io)
            end
            io << "}"
          end
        end
        io << "}"
      end
    end

    def self.from_json_any(value : JSON::Any) : Value
      case raw = value.raw
      when Bool, String then raw
      when Int64        then raw
      when Float64      then raw
      when Int32        then raw.to_i64
      when Array(JSON::Any)
        raw.map { |v| from_json_any(v).as(Int64) }
      when Hash(String, JSON::Any)
        hash = {} of String => String
        raw.each { |k, v| hash[k] = v.to_s }
        hash
      else value.to_s
      end
    end

    # --- analyzer/null_analyzer.rb -----------------------------------

    class NullAnalyzer < Analyzer
      def self.accept?(blob : Blob) : Bool
        true
      end

      def self.analyze_later? : Bool
        false
      end

      def metadata : Hash(String, Value)
        {} of String => Value
      end
    end

    # --- analyzer/image_analyzer.rb ----------------------------------
    # If the image contains EXIF data indicating its angle is 90 or
    # 270 degrees, its width and height are swapped for convenience.

    abstract class ImageAnalyzer < Analyzer
      def self.accept?(blob : Blob) : Bool
        blob.image?
      end
    end

    # --- analyzer/image_analyzer/vips.rb -----------------------------

    class ImageAnalyzer::Vips < ImageAnalyzer
      def self.accept?(blob : Blob) : Bool
        blob.image? && ActiveStorage.variant_processor == :vips
      end

      def metadata : Hash(String, Value)
        download_blob_to_tempfile do |path|
          image = begin
            # ruby-vips raises Vips::Error when no loader matches the
            # file; the gem logs and skips analysis.
            ::Vips::Image.new_from_file(path, access: "sequential")
          rescue ::Vips::Error
            nil
          end
          next {} of String => Value unless image

          if rotated_image?(image)
            {"width" => image.height.to_i64, "height" => image.width.to_i64} of String => Value
          else
            {"width" => image.width.to_i64, "height" => image.height.to_i64} of String => Value
          end
        end
      rescue ::Vips::Error
        {} of String => Value
      end

      ROTATIONS = /Right-top|Left-bottom|Top-right|Bottom-left/

      private def rotated_image?(image : ::Vips::Image) : Bool
        ROTATIONS.matches?(image.get("exif-ifd0-Orientation").to_s)
      rescue ::Vips::Error
        false
      end
    end

    # --- analyzer/image_analyzer/image_magick.rb ---------------------

    class ImageAnalyzer::ImageMagick < ImageAnalyzer
      def self.accept?(blob : Blob) : Bool
        blob.image? && ActiveStorage.variant_processor == :mini_magick
      end

      def metadata : Hash(String, Value)
        download_blob_to_tempfile do |path|
          image = ::MiniMagick::Image.new(path)
          width, height = image.dimensions
          if rotated_image?(path)
            {"width" => height.to_i64, "height" => width.to_i64} of String => Value
          else
            {"width" => width.to_i64, "height" => height.to_i64} of String => Value
          end
        end
      rescue ex : ::MiniMagick::Error | IO::Error
        # identify failed (corrupt image / missing binary) — the gem
        # logs and skips analysis.
        {} of String => Value
      end

      ROTATION_VALUES = %w[RightTop LeftBottom TopRight BottomLeft]

      private def rotated_image?(path : String) : Bool
        stdout = IO::Memory.new
        stderr = IO::Memory.new
        status = Process.run("identify", ["-format", "%[orientation]", path],
          output: stdout, error: stderr)
        return false unless status.success?
        ROTATION_VALUES.includes?(stdout.to_s.chomp)
      end
    end

    # --- analyzer/video_analyzer.rb ----------------------------------
    # Extracts width/height (swapped when rotated 90°/270°), duration,
    # angle, display aspect ratio and audio?/video? via ffprobe.

    class VideoAnalyzer < Analyzer
      def self.accept?(blob : Blob) : Bool
        blob.video?
      end

      def metadata : Hash(String, Value)
        compact_metadata({
          "width"                => width,
          "height"               => height,
          "duration"             => duration,
          "angle"                => angle,
          "display_aspect_ratio" => display_aspect_ratio,
          "audio"                => audio?,
          "video"                => video?,
        })
      end

      private def width : Float64?
        rotated? ? (computed_height || encoded_height) : encoded_width
      end

      private def height : Float64?
        rotated? ? encoded_width : (computed_height || encoded_height)
      end

      private def duration : Float64?
        to_f?(video_stream["duration"]?) || to_f?(container["duration"]?)
      end

      private def angle : Int64?
        if rotate = to_i?(tags["rotate"]?)
          rotate
        elsif matrix = display_matrix
          to_i?(matrix["rotation"]?)
        end
      end

      private def display_matrix : JSON::Any?
        side_data.find { |data| data["side_data_type"]? == "Display Matrix" }
      end

      private def display_aspect_ratio : Array(Int64)?
        if descriptor = video_stream["display_aspect_ratio"]?
          terms = descriptor.to_s.split(":", 2)
          if terms.size == 2
            numerator = terms[0].to_i64?
            denominator = terms[1].to_i64?
            if numerator && denominator && numerator != 0
              [numerator, denominator]
            end
          end
        end
      end

      private def rotated? : Bool
        angle == 90 || angle == 270 || angle == -90 || angle == -270
      end

      private def audio? : Bool
        !audio_stream.raw.as(Hash(String, JSON::Any)).empty?
      end

      private def video? : Bool
        !video_stream.raw.as(Hash(String, JSON::Any)).empty?
      end

      private def computed_height : Float64?
        encoded_width.try { |w| display_height_scale.try { |s| w * s } }
      end

      private def encoded_width : Float64?
        to_f?(video_stream["width"]?)
      end

      private def encoded_height : Float64?
        to_f?(video_stream["height"]?)
      end

      private def display_height_scale : Float64?
        display_aspect_ratio.try { |dar| dar.last.to_f64 / dar.first.to_f64 }
      end

      private def tags : Hash(String, JSON::Any)
        video_stream["tags"]?.try(&.as_h) || {} of String => JSON::Any
      end

      private def side_data : Array(JSON::Any)
        video_stream["side_data_list"]?.try(&.as_a?) || [] of JSON::Any
      end

      @video_stream : JSON::Any?
      @audio_stream : JSON::Any?

      private def video_stream : JSON::Any
        @video_stream ||= streams.find { |s| s["codec_type"]? == "video" } ||
                          JSON::Any.new({} of String => JSON::Any)
      end

      private def audio_stream : JSON::Any
        @audio_stream ||= streams.find { |s| s["codec_type"]? == "audio" } ||
                          JSON::Any.new({} of String => JSON::Any)
      end

      private def streams : Array(JSON::Any)
        probe["streams"]?.try(&.as_a?) || [] of JSON::Any
      end

      private def container : Hash(String, JSON::Any)
        probe["format"]?.try(&.as_h) || {} of String => JSON::Any
      end

      @probe : JSON::Any?

      private def probe : JSON::Any
        @probe ||= download_blob_to_tempfile { |path| probe_from(path) }
          .as(JSON::Any)
      end

      private def probe_from(path : String) : JSON::Any
        stdout = IO::Memory.new
        status = Process.run(ffprobe_path,
          ["-print_format", "json", "-show_streams", "-show_format", "-v", "error", path],
          output: stdout)
        return JSON.parse(stdout.to_s) if status.success?
        JSON.parse("{}")
      rescue File::NotFoundError | IO::Error
        # Errno::ENOENT in the gem — ffprobe isn't installed: skip.
        JSON.parse("{}")
      end

      private def ffprobe_path : String
        "ffprobe"
      end

      # --- shared JSON::Any coercion (Ruby Float()/Integer()) -------

      private def to_f?(value : JSON::Any?) : Float64?
        return nil unless value
        case raw = value.raw
        when Float64 then raw
        when Int64   then raw.to_f64
        when Int32   then raw.to_f64
        when String  then raw.to_f64?
        else              nil
        end
      end

      private def to_i?(value : JSON::Any?) : Int64?
        return nil unless value
        case raw = value.raw
        when Int64 then raw
        when Int32 then raw.to_i64
        when Float64 then raw.to_i64
        when String  then raw.to_i64?
        else              nil
        end
      end

      # Ruby's Hash#compact for the Hash(String, Value?) built above.
      private def compact_metadata(entries : Hash(String, Value?)) : Hash(String, Value)
        result = {} of String => Value
        entries.each do |key, value|
          result[key] = value unless value.nil?
        end
        result
      end
    end

    # --- analyzer/audio_analyzer.rb ----------------------------------
    # Extracts duration, bit_rate, sample_rate and tags via ffprobe.

    class AudioAnalyzer < Analyzer
      def self.accept?(blob : Blob) : Bool
        blob.audio?
      end

      def metadata : Hash(String, Value)
        compact_metadata({
          "duration"    => duration,
          "bit_rate"    => bit_rate,
          "sample_rate" => sample_rate,
          "tags"        => tags,
        })
      end

      private def duration : Float64?
        to_f?(audio_stream["duration"]?)
      end

      private def bit_rate : Int64?
        to_i?(audio_stream["bit_rate"]?)
      end

      private def sample_rate : Int64?
        to_i?(audio_stream["sample_rate"]?)
      end

      private def tags : Hash(String, String)?
        raw = audio_stream["tags"]?.try(&.as_h) || return nil
        return nil if raw.empty?
        hash = {} of String => String
        raw.each { |k, v| hash[k] = v.to_s }
        hash
      end

      @audio_stream : JSON::Any?

      private def audio_stream : JSON::Any
        @audio_stream ||= streams.find { |s| s["codec_type"]? == "audio" } ||
                          JSON::Any.new({} of String => JSON::Any)
      end

      private def streams : Array(JSON::Any)
        probe["streams"]?.try(&.as_a?) || [] of JSON::Any
      end

      @probe : JSON::Any?

      private def probe : JSON::Any
        @probe ||= download_blob_to_tempfile { |path| probe_from(path) }
          .as(JSON::Any)
      end

      private def probe_from(path : String) : JSON::Any
        stdout = IO::Memory.new
        status = Process.run(ffprobe_path,
          ["-print_format", "json", "-show_streams", "-show_format", "-v", "error", path],
          output: stdout)
        return JSON.parse(stdout.to_s) if status.success?
        JSON.parse("{}")
      rescue File::NotFoundError | IO::Error
        JSON.parse("{}")
      end

      private def ffprobe_path : String
        "ffprobe"
      end

      private def to_f?(value : JSON::Any?) : Float64?
        return nil unless value
        case raw = value.raw
        when Float64 then raw
        when Int64   then raw.to_f64
        when Int32   then raw.to_f64
        when String  then raw.to_f64?
        else              nil
        end
      end

      private def to_i?(value : JSON::Any?) : Int64?
        return nil unless value
        case raw = value.raw
        when Int64 then raw
        when Int32 then raw.to_i64
        when Float64 then raw.to_i64
        when String  then raw.to_i64?
        else              nil
        end
      end

      private def compact_metadata(entries : Hash(String, Value?)) : Hash(String, Value)
        result = {} of String => Value
        entries.each do |key, value|
          result[key] = value unless value.nil?
        end
        result
      end
    end
  end

  # The engine's default analyzers list (engine.rb: config
  # .active_storage.analyzers) — the first analyzer whose accept?
  # matches the blob wins; NullAnalyzer is the fallback (Analyzable).
  @@analyzers : Array(Analyzer.class) = [
    Analyzer::ImageAnalyzer::Vips,
    Analyzer::ImageAnalyzer::ImageMagick,
    Analyzer::VideoAnalyzer,
    Analyzer::AudioAnalyzer,
  ]

  def self.analyzers : Array(Analyzer.class)
    @@analyzers
  end

  def self.analyzers=(analyzers : Array(Analyzer.class)) : Nil
    @@analyzers = analyzers
  end

  # Optional job backend for Blob#analyze_later (the gem enqueues
  # ActiveStorage::AnalyzeJob). nil — no backend wired — performs
  # inline. Wired by the opt-in src/analyze_job.cr.
  class_property analyze_job : (Proc(Blob, Nil) | Nil) = nil
end
