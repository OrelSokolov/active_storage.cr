# Identify spec: the Crystal port must mirror the gem's Marcel-backed
# content-type identification (activestorage 8.1.4):
#
#   before_save :identify, if: :unidentified?
#   def identify_content_type =
#     Marcel::MimeType.for(download, name: filename.to_s, declared_type: content_type)
#
# and `create_and_upload!`'s unfurl semantics: a declared content type
# is trusted as-is; a missing one is sniffed from the io's magic bytes
# (magic beats the filename's extension).

require "spec"
require "../src/active_storage_cr"

ID_TEST_URL = ENV["AS_TEST_URL"]? ||
              "postgres://root@/crails_as_test?host=/var/run/postgresql"

ActiveRecord::Base.establish_connection(ID_TEST_URL)

ID_ROOT = File.join(Dir.tempdir, "as_identify_spec_#{Random::Secure.hex(8)}")
ID_SERVICE = ActiveStorage::DiskService.new(ID_ROOT, "Local")
BLOB_IDS = [] of Int64

PNG  = File.read("#{__DIR__}/../oracle/fixtures/cat.png")
GIF  = "GIF89a\x01\x00\x01\x00\x00\x00\x00"

describe "ActiveStorage::Blob#identify (Marcel)" do
  before_each { ActiveStorage.service = ID_SERVICE }

  after_each do
    BLOB_IDS.each do |id|
      blob = ActiveStorage::Blob.find?(id)
      blob.try(&.purge)
    end
    BLOB_IDS.clear
  end

  it "sniffs an undeclared content type from magic bytes" do
    blob = ActiveStorage::Blob.create_and_upload!(io: PNG, filename: "cat.png")
    BLOB_IDS << blob.id.not_nil!
    blob.content_type.should eq("image/png")
    blob.identified?.should be_true
  end

  it "prefers magic bytes over a misleading filename extension" do
    blob = ActiveStorage::Blob.create_and_upload!(io: GIF, filename: "totally_a.png")
    BLOB_IDS << blob.id.not_nil!
    blob.content_type.should eq("image/gif")
  end

  it "falls back to the filename extension when magic is inconclusive" do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: "no magic here, just text-ish bytes", filename: "notes.md")
    BLOB_IDS << blob.id.not_nil!
    blob.content_type.should eq("text/markdown")
  end

  it "trusts a declared content type" do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: PNG, filename: "cat.png", content_type: "application/octet-stream")
    BLOB_IDS << blob.id.not_nil!
    blob.content_type.should eq("application/octet-stream")
  end

  it "identifies an unidentified blob in before_save via download" do
    key = ActiveStorage::Blob.generate_key
    ActiveStorage.service.upload(key, PNG, ActiveStorage::Checksum.md5_base64(PNG))
    blob = ActiveStorage::Blob.create!({
      "key"          => key,
      "filename"     => "mystery.bin",
      "content_type" => nil,
      "metadata"     => nil,
      "service_name" => ActiveStorage.service_name,
      "byte_size"    => PNG.bytesize.to_i64,
      "checksum"     => ActiveStorage::Checksum.md5_base64(PNG),
    })
    BLOB_IDS << blob.id.not_nil!
    blob.content_type.should eq("image/png")

    # persisted, not just in-memory
    ActiveStorage::Blob.find(blob.id.not_nil!).not_nil!.content_type.should eq("image/png")
    blob.identified?.should be_true
    blob.unidentified?.should be_false
  end

  it "keeps magic detection honest for saved-and-reloaded blobs" do
    blob = ActiveStorage::Blob.create_and_upload!(io: GIF, filename: "weird")
    BLOB_IDS << blob.id.not_nil!
    ActiveStorage::Blob.find(blob.id.not_nil!).not_nil!.content_type.should eq("image/gif")
  end
end
