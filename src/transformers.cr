# Port of ActiveStorage::Transformers (activestorage 8.1.4):
# transformer.rb, null_transformer.rb, image_processing_transformer.rb,
# vips.rb, image_magick.rb. Variants are processed through the
# image_processing_cr shard (ImageProcessing::Vips / ::MiniMagick),
# selected by ActiveStorage.variant_processor — the engine equivalent of
# `config.active_storage.variant_processor || :mini_magick` resolved into
# variant_transformer in after_initialize.
#
# Deviations from the gem (documented):
#   * Transformer#transform works on file PATHS and deletes the output
#     file after the block, instead of yielding an open Ruby Tempfile.
#   * The gem's vips.rb hardening (Vips.block_untrusted — libvips >= 8.13)
#     is not ported: image_processing.cr 1.14 does not expose it.
#   * The LoadError guards around require "image_processing" are
#     compile-time requires in Crystal — a missing shard fails the build.

require "image_processing_cr"

module ActiveStorage
  module Transformers
    # Port of transformers/transformer.rb.
    class Transformer
      attr_reader transformations : Hash(String, Variation::Value)

      def initialize(@transformations : Hash(String, Variation::Value))
      end

      # Applies the transformations to the source image at +file+, producing
      # a target image in the specified +format+. Yields the output file
      # path; deletes the output file after yielding (the gem closes and
      # unlinks an open Tempfile). Returns the result of the block.
      def transform(file : String, format : String, &block : String -> _)
        output = process(file, format: format)
        begin
          yield output
        ensure
          File.delete(output) rescue nil unless output == file
        end
      end

      # Returns the transformed image's path. All subclasses implement this
      # method.
      private def process(file : String, format : String) : String
        raise NotImplementedError.new("subclass responsibility")
      end
    end

    # Port of transformers/null_transformer.rb — `variant_processor =
    # :disabled`; passes the file through untouched.
    class NullTransformer < Transformer
      private def process(file : String, format : String) : String
        file
      end
    end

    # Port of transformers/image_processing_transformer.rb.
    class ImageProcessingTransformer < Transformer
      class UnsupportedImageProcessingMethod < Exception; end
      class UnsupportedImageProcessingArgument < Exception; end

      private def process(file : String, format : String) : String
        raise NotImplementedError.new("subclass responsibility")
      end

      # The gem builds `processor.source(file).loader(page: 0).convert(
      # format).apply(operations).call`; the processor module differs per
      # subclass (ImageProcessing::Vips / ::MiniMagick carry different
      # generics, so each subclass spells the pipeline out).
      macro pipeline(processor, file, format)
        {{processor.id}}.source({{file}}).loader(page: 0)
          .convert({{format}}).apply(operations).call
          .as(ImageProcessing::Tempfile).path
      end

      protected def operations : Array(Tuple(String, Variation::Value))
        @transformations.each_with_object([] of Tuple(String, Variation::Value)) do |(name, argument), list|
          validate_transformation(name, argument)
          # Ruby skips blank arguments (`argument.present?`); our Value type
          # is never nil, only the empty string is blank.
          list << {name, argument} unless argument.to_s.empty?
        end
      end

      private def validate_transformation(name : String, argument : Variation::Value) : Nil
        if name == "combine_options"
          raise ArgumentError.new(%(Active Storage's ImageProcessing transformer \
doesn't support :combine_options, as it always generates a single command.))
        end
      end
    end

    # Port of transformers/vips.rb — ActiveStorage.variant_processor = :vips.
    class Vips < ImageProcessingTransformer
      private def process(file : String, format : String) : String
        pipeline(ImageProcessing::Vips, file, format)
      end
    end

    # Port of transformers/image_magick.rb — variant_processor =
    # :mini_magick (the 8.1.4 default).
    class ImageMagick < ImageProcessingTransformer
      private def process(file : String, format : String) : String
        pipeline(ImageProcessing::MiniMagick, file, format)
      end

      private def validate_transformation(name : String, argument : Variation::Value) : Nil
        method_name = name.tr("-", "_")

        unless ActiveStorage.supported_image_processing_methods.includes?(method_name)
          raise UnsupportedImageProcessingMethod.new(
            "The provided transformation method is not supported: #{method_name}.")
        end

        case argument
        when String then validate_arg_string(argument)
        when Array(Int32)
          argument.each { |arg| validate_arg_string(arg.to_s) }
        end

        super
      end

      private def validate_arg_string(argument : String) : Nil
        ActiveStorage.unsupported_image_processing_arguments.each do |bad_arg|
          if argument.downcase.includes?(bad_arg)
            raise UnsupportedImageProcessingArgument.new(argument)
          end
        end
      end
    end
  end

  # Port of the mattr_accessors from active_storage.rb/engine.rb. The gem's
  # engine merges app config after_initialize; the port exposes module
  # accessors with the same 8.1.4 defaults.
  @@variant_processor : Symbol = :mini_magick
  @@variant_transformer : Transformers::Transformer.class | Nil = nil

  def self.variant_processor : Symbol
    @@variant_processor
  end

  def self.variant_processor=(processor : Symbol) : Nil
    @@variant_processor = processor
    @@variant_transformer = nil
  end

  # The gem resolves this in after_initialize; the port resolves lazily from
  # variant_processor (no railtie yet), reset when the processor changes.
  def self.variant_transformer : Transformers::Transformer.class
    @@variant_transformer ||= case variant_processor
    when :disabled    then Transformers::NullTransformer
    when :vips        then Transformers::Vips
    when :mini_magick then Transformers::ImageMagick
    else
      raise ArgumentError.new("unknown variant_processor: #{variant_processor}")
    end
  end

  def self.variant_transformer=(klass : Transformers::Transformer.class) : Nil
    @@variant_transformer = klass
  end

  # The gem's allowlist (mattr_accessor :supported_image_processing_methods,
  # extended by app config in the engine) for the mini_magick transformer.
  SUPPORTED_IMAGE_PROCESSING_METHODS = %w[
    adaptive_blur adaptive_resize adaptive_sharpen adjoin affine alpha annotate
    antialias append attenuate authenticate auto_gamma auto_level auto_orient
    auto_threshold backdrop background bench bias bilateral_blur
    black_point_compensation black_threshold blend blue_primary blue_shift blur
    border bordercolor borderwidth brightness_contrast cache canny caption
    channel channel_fx charcoal chop clahe clamp clip clip_path clone clut
    coalesce colorize colormap color_matrix colors colorspace colourspace
    color_threshold combine combine_options comment compare complex compose
    composite compress connected_components contrast contrast_stretch convert
    convolve copy crop cycle deconstruct define delay delete density depth
    descend deskew despeckle direction displace dispose dissimilarity_threshold
    dissolve distort dither draw duplicate edge emboss encoding endian enhance
    equalize evaluate evaluate_sequence extent extract family features fft fill
    filter flatten flip floodfill flop font foreground format frame function fuzz
    fx gamma gaussian_blur geometry gravity grayscale green_primary hald_clut
    highlight_color hough_lines icongeometry iconic identify ift illuminant
    immutable implode insert intensity intent interlace interline_spacing
    interpolate interpolative_resize interword_spacing kerning kmeans kuwahara
    label lat layers level level_colors limit limits linear_stretch linewidth
    liquid_rescale list log loop lowlight_color magnify map mattecolor median
    mean_shift metric mode modulate moments monitor monochrome morph morphology
    mosaic motion_blur name negate noise normalize opaque ordered_dither orient
    page paint pause perceptible ping pointsize polaroid poly posterize
    precision preview process quality quantize quiet radial_blur raise
    random_threshold range_threshold red_primary regard_warnings region remote
    render repage resample resize resize_to_fill resize_to_fit resize_to_limit
    resize_and_pad respect_parentheses reverse roll rotate sample
    sampling_factor scale scene screen seed selective_blur separate sepia_tone
    shade shadow shared_memory sharpen shave shear sigmoidal_contrast silent
    similarity_threshold size sketch smush snaps solarize sort_pixels
    sparse_color splice spread statistic stegano stereo storage_type stretch
    strip stroke strokewidth style subimage_search swap swirl synchronize taint
    text_font threshold thumbnail tile_offset tint title transform transparent
    transparent_color transpose transverse treedepth trim type undercolor
    unique_colors units unsharp update valid_image view vignette virtual_pixel
    visual watermark wave wavelet_denoise weight white_balance white_point
    white_threshold window window_group
  ]

  def self.supported_image_processing_methods : Array(String)
    SUPPORTED_IMAGE_PROCESSING_METHODS
  end

  # The gem's engine default (`unsupported_image_processing_arguments`).
  UNSUPPORTED_IMAGE_PROCESSING_ARGUMENTS = %w[
    -debug -display -distribute-cache -help -path -print -set -verbose
    -version -write -write-mask
  ]

  def self.unsupported_image_processing_arguments : Array(String)
    UNSUPPORTED_IMAGE_PROCESSING_ARGUMENTS
  end
end
