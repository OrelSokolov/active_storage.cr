# Port of ActiveStorage::Variant — the lazily processed derivative of
# an image blob, uploaded under "variants/{blob.key}/{variation.key}".
# Oracle: var_* cases in oracle/cases_s3.rb.

module ActiveStorage
  class InvariableError < Exception; end
  class UnrepresentableError < Exception; end

  class Variant
    attr_reader blob : Blob
    attr_reader variation : Variation

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

  # Blob::Representable#default_variant_format for a filename/content_type
  # pair, without loading the blob (used by URL builders in views).
  def self.default_variant_format(filename : String, content_type : String) : String
    return "png" unless Blob::WEB_IMAGE_TYPES.includes?(content_type)
    ext = Filename.new(filename).extension.to_s
    fmt = if !ext.empty? && Marcel::MimeType.for(extension: ext) == content_type
      ext
    else
      Marcel::Magic.new(content_type).extensions.first?.to_s
    end
    fmt.presence || "png"
  end

  class Blob
    VARIABLE_CONTENT_TYPES = %w[image/png image/jpeg image/jpg image/gif
                                image/webp image/tiff image/bmp image/avif]

    def variable? : Bool
      VARIABLE_CONTENT_TYPES.includes?(content_type.to_s)
    end

    # previewable? — the registered previewers (port: video/ffmpeg);
    # a blob is representable when variable or previewable (the gem).
    def previewable? : Bool
      ActiveStorage.previewers.any? &.accept?(self)
    end

    def representable? : Bool
      variable? || previewable?
    end

    # Blob::Representable#variant: the variation defaults the format
    # (default_to default_variant_transformations — {format: …} first).
    # Raises InvariableError for non-variable blobs, as in the gem.
    def variant(**options) : Variant
      transformations = {} of String => Variation::Value
      options.each do |k, v|
        transformations[k.to_s] = v.as(Variation::Value)
      end
      variant(transformations)
    end

    def variant(transformations : Hash(String, Variation::Value)) : Variant
      unless variable?
        raise InvariableError.new(
          "Can't transform blob with ID=#{id} and content_type=#{content_type}")
      end
      variation = Variation.new(transformations)
        .default_to({"format" => default_variant_format})
      Variant.new(self, variation)
    end

    # Blob::Representable#preview: raises UnpreviewableError when no
    # registered previewer accepts the blob.
    def preview(**options) : Preview
      transformations = {} of String => Variation::Value
      options.each do |k, v|
        transformations[k.to_s] = v.as(Variation::Value)
      end
      preview(transformations)
    end

    def preview(transformations : Hash(String, Variation::Value)) : Preview
      if previewable?
        Preview.new(self, Variation.new(transformations))
      else
        raise UnpreviewableError.new(
          "No previewer found for blob with ID=#{id} and content_type=#{content_type}")
      end
    end

    # Blob::Representable#representation: a Preview for previewable blobs
    # or a Variant for variable ones.
    def representation(transformations : Hash(String, Variation::Value)) : Variant | Preview
      if previewable?
        preview(transformations)
      elsif variable?
        variant(transformations)
      else
        raise UnrepresentableError.new(
          "No previewer found and can't transform blob with ID=#{id} and content_type=#{content_type}")
      end
    end

    # web_image? (servable.rb): the content types browsers display inline
    # by default.
    WEB_IMAGE_TYPES = %w[image/png image/jpeg image/jpg image/gif image/webp]

    def web_image? : Bool
      WEB_IMAGE_TYPES.includes?(content_type.to_s)
    end

    # Blob::Representable#default_variant_format (private in the gem): a
    # web image keeps the filename extension when it matches the content
    # type (else the type's first Marcel extension); everything else
    # defaults to png.
    def default_variant_format : String
      ActiveStorage.default_variant_format(filename.to_s, content_type.to_s)
    end

    def url(expires_in : Int32 = 300) : String
      ActiveStorage.service.url(key.not_nil!, expires_in: expires_in,
        disposition: "inline", filename: filename.not_nil!.to_s,
        content_type: content_type)
    end
  end
end
