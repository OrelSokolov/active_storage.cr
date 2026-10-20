# Oracle cases for ActiveStorage::Blob::Analyzable + Analyzer
# (activestorage 8.1.4): blob metadata JSON as stored in the DB,
# byte-for-byte.
#
# Run against the ORIGINAL gem:
#   ruby oracle/cases_analyzer.rb > oracle/expected_analyzer.yml
#
# Each line: "<case_id>\t<value>". Mirrored 1:1 in
# spec/analyzer_spec.cr. Fixtures live in oracle/fixtures (generated
# once with vips/convert/ffmpeg; deterministic on this machine).

gem "activestorage", "= 8.1.4"
gem "activerecord", "= 8.1.4"
gem "activesupport", "= 8.1.4"
gem "sqlite3", ">= 2.1"
require "active_storage"
require "digest"
require "tmpdir"
require "stringio"

# Standalone (no railtie): load the gem's app/models by hand — same
# bootstrap as oracle/cases.rb.
ActiveRecord::Base.include ActiveStorage::Attached::Model
require "active_storage/reflection"
ActiveRecord::Reflection.singleton_class.prepend ActiveStorage::Reflection::ReflectionExtension
ActiveRecord::Base.include ActiveStorage::Reflection::ActiveRecordExtensions

AS_GEM = Gem::Specification.find_by_name("activestorage", "= 8.1.4").gem_dir
require "#{AS_GEM}/app/models/active_storage/record.rb"
require "#{AS_GEM}/app/models/active_storage/filename.rb"
module ActiveStorage
  class Blob < ActiveStorage::Record
    self.table_name = "active_storage_blobs"
  end
end
require "#{AS_GEM}/app/models/active_storage/blob/analyzable.rb"
require "#{AS_GEM}/app/models/active_storage/blob/identifiable.rb"
require "#{AS_GEM}/app/models/active_storage/blob/representable.rb"
require "#{AS_GEM}/app/models/active_storage/blob/servable.rb"
require "#{AS_GEM}/app/models/active_storage/blob.rb"
module ActiveStorage
  class Attachment < ActiveStorage::Record
    self.table_name = "active_storage_attachments"
  end
end
require "#{AS_GEM}/app/models/active_storage/attachment.rb"

module Rails
  def self.configuration
    @configuration ||= Config.new
  end

  class Config
    def active_storage
      @active_storage ||= StorageConfig.new
    end

    class StorageConfig
      attr_accessor :service

      def initialize
        @service = :local
      end
    end
  end
end

ActiveRecord::Migration.verbose = false
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.define do
  create_table :active_storage_blobs do |t|
    t.string   :key,          null: false
    t.string   :filename,     null: false
    t.string   :content_type
    t.text     :metadata
    t.string   :service_name, null: false
    t.bigint   :byte_size,    null: false
    t.string   :checksum
    t.datetime :created_at,   null: false
    t.datetime :updated_at
  end
  create_table :active_storage_attachments do |t|
    t.string   :name,         null: false
    t.string   :record_type,  null: false
    t.integer  :record_id,    null: false
    t.integer  :blob_id,      null: false
    t.datetime :created_at,   null: false
  end
end

require "active_storage/service"
require "active_storage/service/disk_service"
require "active_storage/service/registry"
require "logger"

# The railtie wires ActiveStorage.logger; standalone the rescue paths
# would call nil.info — provide a sink.
ActiveStorage.logger = Logger.new(File::NULL)

# The railtie normally registers the default analyzers (engine.rb);
# standalone we require and list them by hand.
require "active_storage/analyzer"
require "active_storage/analyzer/null_analyzer"
require "#{AS_GEM}/lib/active_storage/analyzer/image_analyzer"
require "#{AS_GEM}/lib/active_storage/analyzer/image_analyzer/vips"
require "#{AS_GEM}/lib/active_storage/analyzer/image_analyzer/image_magick"
require "#{AS_GEM}/lib/active_storage/analyzer/video_analyzer"
require "#{AS_GEM}/lib/active_storage/analyzer/audio_analyzer"
ActiveStorage.analyzers = [
  ActiveStorage::Analyzer::ImageAnalyzer::Vips,
  ActiveStorage::Analyzer::ImageAnalyzer::ImageMagick,
  ActiveStorage::Analyzer::VideoAnalyzer,
  ActiveStorage::Analyzer::AudioAnalyzer
]

ROOT = Dir.mktmpdir("as_analyzer_oracle")
ActiveStorage::Blob.services = ActiveStorage::Service::Registry.new(
  {"Local" => {"service" => "Disk", "root" => ROOT}}
)
ActiveStorage::Blob.service = ActiveStorage::Blob.services.fetch("Local")

FIXTURES = File.expand_path("#{__dir__}/fixtures")

def render(v)
  case v
  when String then v
  else v.inspect
  end
end

def case_run(id)
  puts "#{id}\t#{render(yield)}"
rescue StandardError => e
  warn "#{id}: #{e.class}: #{e.message.to_s[0, 300]}"
  puts "#{id}\traise:#{e.class.name}"
end

def analyze_fixture(id, filename, content_type, processor: :vips)
  ActiveStorage.variant_processor = processor
  io = File.binread(File.join(FIXTURES, filename))
  blob = ActiveStorage::Blob.create_and_upload!(
    io: StringIO.new(io), filename: filename, content_type: content_type
  )
  blob.analyze
  # The raw stored JSON — byte-for-byte what the Crystal port writes.
  blob.reload.metadata_before_type_cast
ensure
  # reset processor for the next case
  ActiveStorage.variant_processor = :vips
end

# --- image analyzers (vips) ------------------------------------------
case_run("an_vips_png")        { analyze_fixture("an_vips_png", "cat.png", "image/png") }
case_run("an_vips_jpeg")       { analyze_fixture("an_vips_jpeg", "img.jpeg", "image/jpeg") }
case_run("an_vips_gif")        { analyze_fixture("an_vips_gif", "img.gif", "image/gif") }
case_run("an_vips_webp")       { analyze_fixture("an_vips_webp", "img.webp", "image/webp") }
case_run("an_vips_tiff")       { analyze_fixture("an_vips_tiff", "img.tiff", "image/tiff") }
case_run("an_vips_avif")       { analyze_fixture("an_vips_avif", "img.avif", "image/avif") }
case_run("an_vips_rotated")    { analyze_fixture("an_vips_rotated", "rotated.jpg", "image/jpeg") }
case_run("an_vips_truncated")  { analyze_fixture("an_vips_truncated", "truncated.jpg", "image/jpeg") }

# --- image analyzers (mini_magick) ------------------------------------
case_run("an_im_png")          { analyze_fixture("an_im_png", "cat.png", "image/png", processor: :mini_magick) }
case_run("an_im_jpeg")         { analyze_fixture("an_im_jpeg", "img.jpeg", "image/jpeg", processor: :mini_magick) }
case_run("an_im_rotated")      { analyze_fixture("an_im_rotated", "rotated.jpg", "image/jpeg", processor: :mini_magick) }
case_run("an_im_truncated")    { analyze_fixture("an_im_truncated", "truncated.jpg", "image/jpeg", processor: :mini_magick) }

# --- null analyzer -----------------------------------------------------
case_run("an_null_txt")        { analyze_fixture("an_null_txt", "notimage.txt", "text/plain") }

# --- video/audio analyzers (ffprobe) -----------------------------------
case_run("an_video")           { analyze_fixture("an_video", "video.mp4", "video/mp4") }
case_run("an_video_rot90")     { analyze_fixture("an_video_rot90", "video_rot90.mp4", "video/mp4") }
case_run("an_audio")           { analyze_fixture("an_audio", "audio.mp3", "audio/mpeg") }

# --- API surface -------------------------------------------------------
case_run("an_analyzed_before") do
  io = File.binread(File.join(FIXTURES, "cat.png"))
  blob = ActiveStorage::Blob.create_and_upload!(
    io: StringIO.new(io), filename: "cat.png", content_type: "image/png"
  )
  # truthy/falsy: Ruby nil (no metadata yet) vs the port's false.
  blob.analyzed? ? "truthy" : "falsy"
end

case_run("an_analyzed_after") do
  io = File.binread(File.join(FIXTURES, "cat.png"))
  blob = ActiveStorage::Blob.create_and_upload!(
    io: StringIO.new(io), filename: "cat.png", content_type: "image/png"
  )
  blob.analyze
  blob.reload.analyzed? ? "truthy" : "falsy"
end

case_run("an_idempotent") do
  io = File.binread(File.join(FIXTURES, "cat.png"))
  blob = ActiveStorage::Blob.create_and_upload!(
    io: StringIO.new(io), filename: "cat.png", content_type: "image/png"
  )
  blob.analyze
  first = blob.reload.metadata
  blob.analyze
  second = blob.reload.metadata
  "#{first == second}"
end

case_run("an_analyze_later_inline") do
  # NullAnalyzer.analyze_later? is false → analyze_later performs inline.
  io = File.binread(File.join(FIXTURES, "notimage.txt"))
  blob = ActiveStorage::Blob.create_and_upload!(
    io: StringIO.new(io), filename: "notimage.txt", content_type: "text/plain"
  )
  blob.analyze_later
  blob.reload.metadata_before_type_cast
end
