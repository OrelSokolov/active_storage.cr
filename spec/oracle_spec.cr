# Oracle spec: the Crystal port must reproduce oracle/expected.yml
# exactly (captured from activestorage 8.1.4 via oracle/cases.rb:
# Disk service + SQLite in-memory fixtures). Same case IDs, no edits.
# Purge is covered by a port unit spec (the Ruby standalone harness
# cannot run the gem's purge without a railtie).

require "spec"
require "../src/active_storage_cr"

EXPECTED = begin
  hash = {} of String => String
  current_id : String? = nil
  File.read("#{__DIR__}/../oracle/expected.yml").each_line do |line|
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

TEST_URL = ENV["AS_TEST_URL"]? ||
           "postgres://root@/crails_as_test?host=/var/run/postgresql"

ActiveRecord::Base.establish_connection(TEST_URL)

# Clean tables between runs (oracle used a fresh in-memory DB).
ActiveRecord::Base.connection.exec("DELETE FROM active_storage_attachments")
ActiveRecord::Base.connection.exec("DELETE FROM active_storage_blobs")
ActiveRecord::Base.connection.exec("DELETE FROM users")

class User < ActiveRecord::Base
  has_one_attached :avatar
end

# Disk service in a temp dir, named like the oracle's registry entry.
ROOT = File.join(Dir.tempdir, "as_oracle_spec_#{Random::Secure.hex(8)}")
SERVICE = ActiveStorage::DiskService.new(ROOT, "Local")
ActiveStorage.service = SERVICE

SERVICE.upload("svc/key1", "SERVICE DATA", ActiveStorage::Checksum.md5_base64("SERVICE DATA"))

IO_DATA = "BLOB DATA"
BLOB = ActiveStorage::Blob.create_and_upload!(
  io: IO_DATA, filename: "report.txt", content_type: "text/plain"
)

USER = User.create
USER.avatar.attach(io: "AVATAR BYTES", filename: "me.png", content_type: "image/png")

CASES = {
  # --- disk service ---
  "svc_exists"    => -> { SERVICE.exist?("svc/key1").to_s },
  "svc_download"  => -> { SERVICE.download("svc/key1") },
  "svc_missing"   => -> { SERVICE.exist?("svc/nope").to_s },
  "svc_delete"    => -> { SERVICE.delete("svc/key1"); SERVICE.exist?("svc/key1").to_s },
  # --- filename ---
  "fn_sanitize" => -> { ActiveStorage::Filename.new("fu Man Chu.jpg").sanitized },
  "fn_base"     => -> { ActiveStorage::Filename.new("fu Man Chu.jpg").base },
  "fn_ext"      => -> { ActiveStorage::Filename.new("fu Man Chu.jpg").extension },
  "fn_empty"    => -> { ActiveStorage::Filename.new("").sanitized },
  # --- blob ---
  "blob_byte_size"    => -> { BLOB.byte_size.to_s },
  "blob_checksum"     => -> { BLOB.checksum },
  "blob_md5_manual"   => -> { ActiveStorage::Checksum.md5_base64(IO_DATA) },
  "blob_content_type" => -> { BLOB.content_type },
  "blob_filename"     => -> { BLOB.filename },
  "blob_key_shape"    => -> { !!(BLOB.key =~ /\A[A-Za-z0-9]{20,30}\z/).to_s },
  "blob_find"         => -> { (ActiveStorage::Blob.find(BLOB.id.not_nil!).key == BLOB.key).to_s },
  "blob_download"     => -> { BLOB.download },
  "blob_text?"        => -> { BLOB.text?.to_s },
  "blob_image?"       => -> { BLOB.image?.to_s },
  "blob_video?"       => -> { BLOB.video?.to_s },
  # --- has_one_attached ---
  "att_attached"   => -> { USER.avatar.attached?.to_s },
  "att_blob_size"  => -> { USER.avatar_blob.not_nil!.byte_size.to_s },
  "att_blob_ct"    => -> { USER.avatar_blob.not_nil!.content_type },
  "att_image?"     => -> { USER.avatar_blob.not_nil!.image?.to_s },
  "att_download"   => -> { USER.avatar.download },
  "att_filename"   => -> { USER.avatar.filename },
  "att_new_user"   => -> { User.create.avatar.attached?.to_s },
  "att_detach"     => -> { USER.avatar.detach; [USER.avatar.attached?, USER.avatar_blob.nil?].inspect },
}

describe "active_storage oracle (activestorage 8.1.4)" do
  EXPECTED.each do |id, expected|
    it id do
      # The S3 spec file may swap the global service at load time;
      # pin it back while the disk-oracle cases run.
      ActiveStorage.service = SERVICE
      block = CASES[id]?
      block.should_not be_nil, "case #{id} not mirrored in spec"
      result = begin
        block.not_nil!.call.to_s
      rescue ex : Exception
        "raise:#{ex.class.name}"
      end
      result.strip.should eq(expected.strip), <<-MSG
        #{id}:
          expected: #{expected.inspect}
          got:      #{result.inspect}
        MSG
    end
  end

  it "mirrors every oracle case" do
    missing = EXPECTED.keys - CASES.keys
    extra = CASES.keys - EXPECTED.keys
    missing.should be_empty
    extra.should be_empty
  end
end

describe "active_storage purge (port unit)" do
  it "removes attachment row, blob row and service file" do
    ActiveStorage.service = SERVICE
    blob = ActiveStorage::Blob.create_and_upload!(
      io: "PURGE ME", filename: "p.txt", content_type: "text/plain")
    user = User.create
    user.avatar.attach(io: "PURGE ME", filename: "p.txt", content_type: "text/plain")
    key = blob.key

    blob.purge

    ActiveStorage::Blob.find?(blob.id.not_nil!).should be_nil
    ActiveStorage::Attachment.where("blob_id = ?", blob.id.not_nil!).to_a.should be_empty
    SERVICE.exist?(key.not_nil!).should be_false
  end
end
