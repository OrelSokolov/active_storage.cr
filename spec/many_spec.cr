# Oracle spec: has_many_attached — the Crystal port must reproduce
# oracle/expected_many.yml exactly (captured from activestorage 8.1.4 via
# oracle/cases_many.rb: SQLite in-memory, Disk service). Same case IDs,
# no edits.
#
# The oracle counted rows in a fresh in-memory DB; this suite shares the
# PG test database with the other spec files, so the row-count cases
# (many_purge/many_detach) count the rows this flow created — the same
# semantics without depending on neighbours' fixtures.
#
# Fixtures are created lazily (before_all): oracle_spec.cr loads before
# this file and its rows must survive until its examples have run; the
# table wipe happens here only once this group's turn comes.

require "spec"
require "../src/active_storage_cr"

MANY_EXPECTED = begin
  hash = {} of String => String
  current_id : String? = nil
  File.read("#{__DIR__}/../oracle/expected_many.yml").each_line do |line|
    if line.includes?('\t')
      id, value = line.split('\t', 2)
      hash[id] = value.chomp
      current_id = id
    elsif cur = current_id
      hash[cur] = hash[cur] + "\n" + line.chomp
    end
  end
  hash
end

MANY_TEST_URL = ENV["AS_TEST_URL"]? ||
                "postgres://root@/crails_as_test?host=/var/run/postgresql"

ActiveRecord::Base.establish_connection(MANY_TEST_URL)

class Gallery < ActiveRecord::Base
  has_many_attached :photos
end

MANY_ROOT = File.join(Dir.tempdir, "as_many_spec_#{Random::Secure.hex(8)}")
MANY_SERVICE = ActiveStorage::DiskService.new(MANY_ROOT, "Local")

MANY_GALLERY_HOLDER = [] of Gallery

def many_gallery : Gallery
  MANY_GALLERY_HOLDER.first
end

# Blob rows created by this flow (for the purge/detach count cases).
MANY_BLOB_IDS = [] of Int64

MANY_CASES = {
  "many_attached"        => -> { many_gallery.photos.attached?.to_s },
  "many_order"           => -> { many_gallery.photos.map(&.blob.filename.to_s).inspect },
  "many_blobs_sizes"     => -> { many_gallery.photos.blobs.map(&.byte_size).inspect },
  "many_blobs_types"     => -> { many_gallery.photos.blobs.map(&.content_type).inspect },
  "many_dl_first"        => -> { many_gallery.photos.blobs.first.download },
  "many_dl_last"         => -> { many_gallery.photos.blobs.last.download },
  "many_attachments_cnt" => -> { many_gallery.photos_attachments.size.to_s },
  "many_blobs_cnt"       => -> { many_gallery.photos_blobs.size.to_s },
  "many_detach"          => -> {
    blob_ids = many_gallery.photos.blobs.map(&.id.not_nil!)
    many_gallery.photos.detach
    [many_gallery.photos.attached?,
     blob_ids.all? { |id| !ActiveStorage::Blob.find?(id).nil? }].inspect
  },
  "many_purge"           => -> {
    keys = many_gallery.photos.blobs.map(&.key.not_nil!)
    many_gallery.photos.purge
    attachments_left = ActiveStorage::Attachment.where(
      "record_id = ?", many_gallery.id.not_nil!).to_a.size
    blobs_left = MANY_BLOB_IDS.count { |id| !ActiveStorage::Blob.find?(id).nil? }
    [many_gallery.photos.attached?,
     attachments_left,
     blobs_left,
     keys.all? { |k| !MANY_SERVICE.exist?(k) }].inspect
  },
}

describe "active_storage has_many_attached oracle (activestorage 8.1.4)" do
  before_all do
    ActiveRecord::Base.connection.exec("DELETE FROM active_storage_attachments")
    ActiveRecord::Base.connection.exec("DELETE FROM active_storage_blobs")
    ActiveRecord::Base.connection.exec("DELETE FROM galleries")
    ActiveStorage.service = MANY_SERVICE
    MANY_GALLERY_HOLDER << Gallery.create
  end

  # Sequence-sensitive cases (attach steps from the oracle harness).
  it "many_attach_sequence" do
    Gallery.create.photos.attached?.should be_false # many_attached_new
    many_gallery.photos.attachments.size.should eq(0) # many_empty_count
    many_gallery.photos.attach(io: "ONE", filename: "one.png", content_type: "image/png")
    many_gallery.photos.attachments.size.should eq(1) # many_count_1
    many_gallery.photos.attach(io: "TWO", filename: "two.jpg", content_type: "image/jpeg")
    many_gallery.photos.attach(io: "THREE", filename: "three.gif", content_type: "image/gif")

    many_gallery.photos.attached?.should be_true                    # many_attached
    MANY_CASES["many_order"].call.should eq(MANY_EXPECTED["many_order"])
    MANY_CASES["many_blobs_sizes"].call.should eq(MANY_EXPECTED["many_blobs_sizes"])
    MANY_CASES["many_blobs_types"].call.should eq(MANY_EXPECTED["many_blobs_types"])
    many_gallery.photos.blobs.first.download.should eq("ONE")       # many_dl_first
    many_gallery.photos.blobs.last.download.should eq("THREE")      # many_dl_last
    many_gallery.photos_attachments.size.should eq(3)               # many_attachments_cnt
    many_gallery.photos_blobs.size.should eq(3)                     # many_blobs_cnt

    # array attach (many_count_5)
    many_gallery.photos.attach([
      {"FOUR", "four.txt", "text/plain"},
      {"FIVE", "five.txt", "text/plain"},
    ] of Tuple(String, String, String))
    many_gallery.photos.map(&.blob.filename.to_s).inspect.should eq(MANY_EXPECTED["many_count_5"])

    # attach an existing Blob instance (many_count_6 + many_blob_shared)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: "SIX", filename: "six.png", content_type: "image/png")
    MANY_BLOB_IDS.concat(many_gallery.photos.blobs.map(&.id.not_nil!))
    MANY_BLOB_IDS << blob.id.not_nil!
    many_gallery.photos.attach(blob)
    many_gallery.photos.map(&.blob.filename.to_s).inspect.should eq(MANY_EXPECTED["many_count_6"])
    ActiveStorage::Attachment.where(blob_id: blob.id).to_a.size.should eq(1)

    # detach keeps blobs (many_detach)
    MANY_CASES["many_detach"].call.should eq(MANY_EXPECTED["many_detach"])

    # re-attach after detach starts fresh (many_reattach)
    many_gallery.photos.attach(io: "SEVEN", filename: "seven.png", content_type: "image/png")
    MANY_BLOB_IDS.concat(many_gallery.photos.blobs.map(&.id.not_nil!))
    many_gallery.photos.map(&.blob.filename.to_s).inspect.should eq(MANY_EXPECTED["many_reattach"])

    # purge removes attachments + blobs + service files (many_purge)
    MANY_CASES["many_purge"].call.should eq(MANY_EXPECTED["many_purge"])
  end

  it "mirrors every oracle case" do
    covered = MANY_CASES.keys + %w[many_attached_new many_empty_count many_count_1
                                    many_count_5 many_count_6 many_blob_shared many_reattach]
    missing = MANY_EXPECTED.keys - covered
    missing.should be_empty
    extra = MANY_CASES.keys - MANY_EXPECTED.keys
    extra.should be_empty
  end

  it "attach by signed_id (direct-upload form)" do
    ActiveStorage.service = MANY_SERVICE
    blob = ActiveStorage::Blob.create_and_upload!(
      io: "SIGNED", filename: "sig.png", content_type: "image/png")
    many_gallery.photos.attach(blob.signed_id)
    many_gallery.photos.blobs.map(&.byte_size).should eq([6])
    many_gallery.photos.blobs.first.download.should eq("SIGNED")
    many_gallery.photos.purge
  end
end
