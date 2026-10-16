# Transformers spec: the port of ActiveStorage::Transformers
# (activestorage 8.1.4) — variants routed through image_processing_cr.
# The S3 oracle spec replays the gem's var_* cases (captured with the vips
# processor pinned); this unit spec covers BOTH processors and the
# transformer selection/validation logic the oracle does not reach.

require "spec"
require "process"
require "../src/active_storage_cr"

TR_PNG = File.read("#{__DIR__}/../oracle/fixtures/cat.png") # 300x180

def dimensions_of(data : Bytes) : String
  tmp = File.tempfile("dim", ".png") { |f| f.write(data) }
  buf = IO::Memory.new
  Process.run("vipsheader", [tmp.path], output: buf, error: Process::Redirect::Close)
  File.delete(tmp.path)
  buf.to_s.match(/(\d+x\d+)/).not_nil![1]
end

def with_processor(processor : Symbol, &)
  previous = ActiveStorage.variant_processor
  ActiveStorage.variant_processor = processor
  begin
    yield
  ensure
    ActiveStorage.variant_processor = previous
  end
end

describe "ActiveStorage::Transformers" do
  it "defaults variant_processor to :mini_magick (8.1.4)" do
    # The engine: `config.active_storage.variant_processor || :mini_magick`.
    with_processor(:mini_magick) do
      ActiveStorage.variant_processor.should eq(:mini_magick)
      ActiveStorage.variant_transformer.should eq(ActiveStorage::Transformers::ImageMagick)
    end
  end

  it "resolves :vips to Transformers::Vips and :disabled to NullTransformer" do
    with_processor(:vips) do
      ActiveStorage.variant_transformer.should eq(ActiveStorage::Transformers::Vips)
    end
    with_processor(:disabled) do
      ActiveStorage.variant_transformer.should eq(ActiveStorage::Transformers::NullTransformer)
    end
  end

  it "raises on an unknown variant_processor" do
    with_processor(:bogus) do
      expect_raises(ArgumentError) { ActiveStorage.variant_transformer }
    end
  end

  it "processes a variation through the vips transformer" do
    with_processor(:vips) do
      variation = ActiveStorage::Variation.new({"resize_to_limit" => [100, 100]} of String => ActiveStorage::Variation::Value)
      result = variation.transform(TR_PNG, "png")
      dimensions_of(result).should eq("100x60")
      variation.content_type.should eq("image/png")
    end
  end

  it "processes a variation through the mini_magick transformer" do
    with_processor(:mini_magick) do
      variation = ActiveStorage::Variation.new({"resize_to_fill" => [50, 50]} of String => ActiveStorage::Variation::Value)
      result = variation.transform(TR_PNG, "png")
      dimensions_of(result).should eq("50x50")
    end
  end

  it "forwards any image_processing operation (no op whitelist on vips)" do
    with_processor(:vips) do
      variation = ActiveStorage::Variation.new({"resize_to_fit" => [60, 60]} of String => ActiveStorage::Variation::Value)
      dimensions_of(variation.transform(TR_PNG, "png")).should eq("60x36")
    end
  end

  it "converts formats through the transformer" do
    with_processor(:vips) do
      variation = ActiveStorage::Variation.new({"format" => "webp", "resize_to_limit" => [100, 100]} of String => ActiveStorage::Variation::Value)
      result = variation.transform(TR_PNG, "png")
      result.size.should be > 0
      variation.content_type.should eq("image/webp")
      variation.format.should eq("webp")
    end
  end

  it "validates the format through Marcel (Marcel::Magic.by_extension)" do
    variation = ActiveStorage::Variation.new({"format" => "bogus"} of String => ActiveStorage::Variation::Value)
    expect_raises(ArgumentError, /Invalid variant format/) { variation.format }

    ActiveStorage::Variation.new({"format" => "jpg"} of String => ActiveStorage::Variation::Value).content_type.should eq("image/jpeg")
    # default format is png, like the gem's fetch(:format, :png)
    ActiveStorage::Variation.new({} of String => ActiveStorage::Variation::Value)
      .format.should eq("png")
  end

  it "rejects combine_options in the ImageProcessing transformer" do
    with_processor(:vips) do
      variation = ActiveStorage::Variation.new({"combine_options" => "-strip"} of String => ActiveStorage::Variation::Value)
      expect_raises(ArgumentError, /combine_options/) { variation.transform(TR_PNG, "png") }
    end
  end

  it "rejects unsupported methods in the mini_magick transformer" do
    with_processor(:mini_magick) do
      variation = ActiveStorage::Variation.new({"system" => "rm -rf /"} of String => ActiveStorage::Variation::Value)
      expect_raises(ActiveStorage::Transformers::ImageProcessingTransformer::UnsupportedImageProcessingMethod) do
        variation.transform(TR_PNG, "png")
      end
    end
  end

  it "rejects unsupported arguments in the mini_magick transformer" do
    with_processor(:mini_magick) do
      variation = ActiveStorage::Variation.new({"label" => "-write /etc/pwned"} of String => ActiveStorage::Variation::Value)
      expect_raises(ActiveStorage::Transformers::ImageProcessingTransformer::UnsupportedImageProcessingArgument) do
        variation.transform(TR_PNG, "png")
      end
    end
  end

  it "passes the file through with the NullTransformer (:disabled)" do
    with_processor(:disabled) do
      variation = ActiveStorage::Variation.new({"resize_to_limit" => [100, 100]} of String => ActiveStorage::Variation::Value)
      result = variation.transform(TR_PNG, "png")
      result.should eq(TR_PNG.to_slice) # untouched bytes
    end
  end
end
