# Analyzer oracle spec: the Crystal port must reproduce
# oracle/expected_analyzer.yml (captured from activestorage 8.1.4 via
# oracle/cases_analyzer.rb: Disk service + SQLite in-memory fixtures,
# default analyzers list registered by hand — standalone no railtie).
#
# Deviation vs the oracle values (documented in src/analyzer.cr): the
# 8.1.4 gem ALSO stores "identified":true in blob metadata (the port's
# Blob#identify predates the metadata-based flag); expected values are
# compared with the leading {"identified":true,} stripped.

require "spec"
require "../src/active_storage_cr"

EXPECTED_ANALYZER = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../oracle/expected_analyzer.yml").each_line do |line|
    next unless line.includes?('\t')
    id, value = line.split('\t', 2)
    hash[id] = value.chomp
  end
  hash
end

TEST_URL_ANALYZER = ENV["AS_TEST_URL"]? ||
           "postgres://root@/crails_as_test?host=/var/run/postgresql"

ActiveRecord::Base.establish_connection(TEST_URL_ANALYZER)

ANALYZER_ROOT = File.join(Dir.tempdir, "as_analyzer_spec_#{Random::Secure.hex(8)}")
ANALYZER_SERVICE = ActiveStorage::DiskService.new(ANALYZER_ROOT, "Local")
ActiveStorage.service = ANALYZER_SERVICE

FIXTURES = "#{__DIR__}/../oracle/fixtures"

def fixture_bytes(filename : String) : String
  File.read(File.join(FIXTURES, filename))
end

# Blob metadata after analyze, as the raw stored JSON string (the
# oracle's metadata_before_type_cast). "identified" is stripped — see
# the header note.
def analyzed_metadata(filename : String, content_type : String,
                      processor : Symbol = :vips) : String
  ActiveStorage.variant_processor = processor
  blob = ActiveStorage::Blob.create_and_upload!(
    io: fixture_bytes(filename), filename: filename, content_type: content_type
  )
  blob.analyze
  ActiveStorage::Blob.find(blob.id.not_nil!).metadata.to_s
ensure
  ActiveStorage.variant_processor = :vips
end

ANALYZER_CASES = {
  # --- image analyzers (vips) ---
  "an_vips_png"       => -> { analyzed_metadata("cat.png", "image/png") },
  "an_vips_jpeg"      => -> { analyzed_metadata("img.jpeg", "image/jpeg") },
  "an_vips_gif"       => -> { analyzed_metadata("img.gif", "image/gif") },
  "an_vips_webp"      => -> { analyzed_metadata("img.webp", "image/webp") },
  "an_vips_tiff"      => -> { analyzed_metadata("img.tiff", "image/tiff") },
  "an_vips_avif"      => -> { analyzed_metadata("img.avif", "image/avif") },
  "an_vips_rotated"   => -> { analyzed_metadata("rotated.jpg", "image/jpeg") },
  "an_vips_truncated" => -> { analyzed_metadata("truncated.jpg", "image/jpeg") },
  # --- image analyzers (mini_magick) ---
  "an_im_png"       => -> { analyzed_metadata("cat.png", "image/png", :mini_magick) },
  "an_im_jpeg"      => -> { analyzed_metadata("img.jpeg", "image/jpeg", :mini_magick) },
  "an_im_rotated"   => -> { analyzed_metadata("rotated.jpg", "image/jpeg", :mini_magick) },
  "an_im_truncated" => -> { analyzed_metadata("truncated.jpg", "image/jpeg", :mini_magick) },
  # --- null analyzer ---
  "an_null_txt" => -> { analyzed_metadata("notimage.txt", "text/plain") },
  # --- video/audio analyzers (ffprobe) ---
  "an_video"       => -> { analyzed_metadata("video.mp4", "video/mp4") },
  "an_video_rot90" => -> { analyzed_metadata("video_rot90.mp4", "video/mp4") },
  "an_audio"       => -> { analyzed_metadata("audio.mp3", "audio/mpeg") },
  # --- API surface ---
  "an_analyzed_before" => -> {
    blob = ActiveStorage::Blob.create_and_upload!(
      io: fixture_bytes("cat.png"), filename: "cat.png", content_type: "image/png")
    blob.analyzed? ? "truthy" : "falsy"
  },
  "an_analyzed_after" => -> {
    blob = ActiveStorage::Blob.create_and_upload!(
      io: fixture_bytes("cat.png"), filename: "cat.png", content_type: "image/png")
    blob.analyze
    ActiveStorage::Blob.find(blob.id.not_nil!).analyzed? ? "truthy" : "falsy"
  },
  "an_idempotent" => -> {
    blob = ActiveStorage::Blob.create_and_upload!(
      io: fixture_bytes("cat.png"), filename: "cat.png", content_type: "image/png")
    blob.analyze
    first = ActiveStorage::Blob.find(blob.id.not_nil!).metadata
    blob.analyze
    second = ActiveStorage::Blob.find(blob.id.not_nil!).metadata
    (first == second).to_s
  },
  "an_analyze_later_inline" => -> {
    # NullAnalyzer.analyze_later? is false → analyze_later performs
    # inline (no job backend wired).
    blob = ActiveStorage::Blob.create_and_upload!(
      io: fixture_bytes("notimage.txt"), filename: "notimage.txt",
      content_type: "text/plain")
    blob.analyze_later
    ActiveStorage::Blob.find(blob.id.not_nil!).metadata.to_s
  },
}

describe "active_storage analyzer oracle (activestorage 8.1.4)" do
  # Clean tables HERE, not at load time: load-time DELETEs would wipe
  # rows other spec groups create during their own load phase (they
  # run their examples before this group's — see spec/oracle_spec.cr).
  before_all do
    ActiveRecord::Base.connection.exec("DELETE FROM active_storage_attachments")
    ActiveRecord::Base.connection.exec("DELETE FROM active_storage_blobs")
  end

  EXPECTED_ANALYZER.each do |id, expected|
    it id do
      ActiveStorage.service = ANALYZER_SERVICE
      block = ANALYZER_CASES[id]?
      block.should_not be_nil, "case #{id} not mirrored in spec"
      result = begin
        block.not_nil!.call.to_s
      rescue ex : Exception
        "raise:#{ex.class.name}"
      end
      # Strip the gem-only {"identified":true,} prefix (header note).
      normalized = expected.sub(/^\{"identified":true,/, "{")
      result.strip.should eq(normalized.strip), <<-MSG
        #{id}:
          expected: #{normalized.inspect}
          got:      #{result.inspect}
        MSG
    end
  end

  it "mirrors every oracle case" do
    (EXPECTED_ANALYZER.keys - ANALYZER_CASES.keys).should be_empty
    (ANALYZER_CASES.keys - EXPECTED_ANALYZER.keys).should be_empty
  end
end
