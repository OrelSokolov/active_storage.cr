# Port of ActiveStorage::Variation — a set of transformations applied to
# a blob to build a variant. The gem routes transformations through the
# image_processing gem (ruby-vips); the port shells out to the `vips`
# CLI (libvips is the same engine underneath).
#
# `#key` is a 64-hex digest of the transformations (Rails signs the
# transformations with the app's verifier and SHA256-hexes the result —
# same shape, different bytes; documented deviation: signed verifier is
# Rails-internal).

require "openssl"
require "process"
require "json"

module ActiveStorage
  class Variation
    class Error < Exception; end

    alias Value = Array(Int32) | Int32 | String

    CONTENT_TYPES = {
      "png"  => "image/png",
      "jpg"  => "image/jpeg",
      "jpeg" => "image/jpeg",
      "webp" => "image/webp",
      "gif"  => "image/gif",
      "tiff" => "image/tiff",
      "tif"  => "image/tiff",
      "bmp"  => "image/bmp",
      "avif" => "image/avif",
    }

    getter transformations : Hash(String, Value)

    def initialize(@transformations : Hash(String, Value))
    end

    # Default output format is png (the gem: transformations.fetch(:format, :png)).
    def format : String
      f = case v = @transformations["format"]?
          when String then v
          else "png"
          end.downcase
      raise ArgumentError.new("Invalid variant format (#{f.inspect})") unless CONTENT_TYPES[f]?
      f
    end

    def content_type : String
      CONTENT_TYPES[format]
    end

    # 64-hex key identifying these transformations.
    def key : String
      OpenSSL::Digest.new("SHA256").update(canonical_json).final.hexstring
    end

    # Runs the transformations against raw image bytes and returns the
    # encoded result in #format.
    def transform(input : String | Bytes, source_format : String = "png") : Bytes
      input = input.to_slice if input.is_a?(String)
      tmp = File.join(Dir.tempdir, "as_variant_#{Random::Secure.hex(8)}")
      src = "#{tmp}.in.#{source_format}"
      File.write(src, input)

      current = src
      final_ext = format
      begin
        @transformations.each do |op, arg|
          new_file = "#{tmp}.#{op}.#{final_ext}"
          run_step(op, arg, current, new_file)
          current = new_file
        end
        # No-op transformations still need a format conversion step.
        if current == src
          converted = "#{tmp}.copy.#{final_ext}"
          vips("copy", current, converted)
          current = converted
        end
        File.read(current).to_slice
      ensure
        Dir.glob("#{tmp}*").each { |f| File.delete(f) rescue nil }
      end
    end

    private def run_step(op : String, arg : Value, input : String, output : String) : Nil
      case op
      when "resize_to_limit"
        w, h = dims(arg)
        vips("thumbnail", input, output, "#{w}x#{h}", "--size=down")
      when "resize_to_fill"
        w, h = dims(arg)
        vips("thumbnail", input, output, "#{w}x#{h}", "--crop=attention")
      when "resize_and_pad"
        w, h = dims(arg)
        fit = "#{tmp_sibling(output)}.fit.png"
        vips("thumbnail", input, fit, "#{w}x#{h}", "--size=down")
        fw, fh = header_size(fit)
        vips("embed", fit, output, ((w - fw) // 2).to_s, ((h - fh) // 2).to_s,
          w.to_s, h.to_s, "--background", "0")
        File.delete(fit) rescue nil
      when "rotate"
        deg = arg.as(Int32) % 360
        deg += 360 if deg < 0
        raise ArgumentError.new("rotate must be a multiple of 90") unless deg % 90 == 0
        vips("rot", input, output, "d#{deg}")
      when "crop"
        x, y, w, h = arg.as(Array(Int32))
        vips("crop", input, output, x.to_s, y.to_s, w.to_s, h.to_s)
      else
        raise Error.new("unsupported transformation: #{op}")
      end
    end

    private def dims(arg : Value) : {Int32, Int32}
      a = arg.as(Array(Int32))
      raise ArgumentError.new("expected [width, height]") unless a.size == 2
      {a[0], a[1]}
    end

    private def tmp_sibling(path : String) : String
      path.rchop(File.extname(path))
    end

    # "file.png: 300x180 uchar..." → {300, 180}
    private def header_size(path : String) : {Int32, Int32}
      buf = IO::Memory.new
      Process.run("vipsheader", [path], output: buf, error: Process::Redirect::Close)
      if m = buf.to_s.match(/(\d+)x(\d+)/)
        {m[1].to_i, m[2].to_i}
      else
        raise Error.new("vipsheader failed for #{path}")
      end
    end

    private def vips(*args : String) : Nil
      result = Process.run("vips", args.to_a,
        output: Process::Redirect::Close, error: Process::Redirect::Inherit)
      unless result.success?
        raise Error.new("vips #{args.join(" ")} failed (#{result.exit_code})")
      end
    end

    # {"format"=>"webp","resize_to_limit"=>[100,100]} — insertion-ordered
    # like Ruby's JSON.dump for the gem's key derivation.
    private def canonical_json : String
      String.build do |io|
        io << "{"
        @transformations.each_with_index do |(k, v), i|
          io << "," if i > 0
          io << k.to_json << ":"
          case v
          when Array then io << "[" << v.join(",") << "]"
          else            io << v.to_json
          end
        end
        io << "}"
      end
    end
  end
end
