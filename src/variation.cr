# Port of ActiveStorage::Variation — a set of transformations applied to
# a blob to build a variant. As of the gem's 8.1.4 layout, transformations
# run through ActiveStorage::Transformers (image_processing), format is
# validated with Marcel::Magic.by_extension and the content type comes
# from Marcel::MimeType.for(extension:) — no hardcoded table. The
# transformers live in transformers.cr; this file keeps the variation's
# key/format/content_type and the Bytes-in/Bytes-out transform wrapper
# around the gem's file-based Transformer#transform.
#
# `#key` is a 64-hex digest of the transformations (Rails signs the
# transformations with the app's verifier and SHA256-hexes the result —
# same shape, different bytes; documented deviation: signed verifier is
# Rails-internal).

require "openssl"
require "marcel_cr"

module ActiveStorage
  class Variation
    class Error < Exception; end

    alias Value = Array(Int32) | Int32 | String

    getter transformations : Hash(String, Value)

    def initialize(@transformations : Hash(String, Value))
    end

    # transformations.fetch(:format, :png), validated through Marcel
    # (the gem: `Marcel::Magic.by_extension(format).nil? → ArgumentError`).
    def format : String
      f = case v = @transformations["format"]?
          when String then v.downcase
          else "png"
          end
      raise ArgumentError.new("Invalid variant format (#{f.inspect})") unless Marcel::Magic.by_extension(f)
      f
    end

    # The gem: Marcel::MimeType.for(extension: format).
    def content_type : String
      Marcel::MimeType.for(extension: format)
    end

    # 64-hex key identifying these transformations.
    def key : String
      OpenSSL::Digest.new("SHA256").update(canonical_json).final.hexstring
    end

    # Runs the transformations against raw image bytes and returns the
    # encoded result in #format. The gem hands a File to the transformer
    # (`transformer.transform(file, format:)`); the port stages the bytes
    # in a temp file and reads the transformed output back.
    def transform(input : String | Bytes, source_format : String = "png") : Bytes
      input = input.to_slice if input.is_a?(String)
      tmp = File.join(Dir.tempdir, "as_variant_#{Random::Secure.hex(8)}")
      src = "#{tmp}.in.#{source_format}"
      File.write(src, input)

      begin
        bytes = Bytes.new(0)
        ActiveStorage.variant_transformer
          .new(transformations_without_format)
          .transform(src, format: format) { |output| bytes = File.read(output).to_slice }
        bytes
      ensure
        File.delete(src) rescue nil
      end
    end

    # The gem builds the transformer with `transformations.except(:format)`.
    private def transformations_without_format : Hash(String, Value)
      dup = @transformations.dup
      dup.delete("format")
      dup
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
