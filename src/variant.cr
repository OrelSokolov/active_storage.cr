# Port of ActiveStorage::Variant — the lazily processed derivative of
# an image blob, uploaded under "variants/{blob.key}/{variation.key}".
# Oracle: var_* cases in oracle/cases_s3.rb.

module ActiveStorage
  class Variant
    getter blob : Blob
    getter variation : Variation

    def initialize(@blob : Blob, @variation : Variation)
    end

    # Combination key of the blob and the variation (the gem SHA256-
    # hexes its signed variation key; our Variation#key is already a
    # 64-hex digest, so the shapes match).
    def key : String
      "variants/#{blob.key}/#{variation.key}"
    end

    def processed : self
      process unless processed?
      self
    end

    def processed? : Bool
      ActiveStorage.service.exist?(key)
    end

    def download : String
      ActiveStorage.service.download(key)
    end

    def url(expires_in : Int32 = 300, disposition : String = "inline") : String
      ActiveStorage.service.url(key, expires_in: expires_in,
        disposition: disposition, filename: filename.to_s,
        content_type: variation.content_type)
    end

    def filename : Filename
      Filename.new("#{Filename.new(blob.filename.not_nil!).base}.#{variation.format}")
    end

    def content_type : String
      variation.content_type
    end

    def destroy : Nil
      ActiveStorage.service.delete(key)
    end

    private def process : Nil
      source = ActiveStorage.service.download(blob.key.not_nil!)
      ext = Filename.new(blob.filename.not_nil!).extension
      ext = "png" if ext.empty?
      output = variation.transform(source, ext)
      ActiveStorage.service.upload(key, output, content_type: variation.content_type)
    end
  end

  class Blob
    VARIABLE_CONTENT_TYPES = %w[image/png image/jpeg image/jpg image/gif
                                image/webp image/tiff image/bmp image/avif]

    def variable? : Bool
      VARIABLE_CONTENT_TYPES.includes?(content_type.to_s)
    end

    # previewable? needs previewers (ffmpeg/poppler) — P2; a blob is
    # representable in the port when it is variable.
    def representable? : Bool
      variable?
    end

    def variant(**options) : Variant
      transformations = {} of String => Variation::Value
      options.each do |k, v|
        transformations[k.to_s] = v.as(Variation::Value)
      end
      Variant.new(self, Variation.new(transformations))
    end

    def url(expires_in : Int32 = 300) : String
      ActiveStorage.service.url(key.not_nil!, expires_in: expires_in,
        disposition: "inline", filename: filename.not_nil!.to_s,
        content_type: content_type)
    end
  end
end
