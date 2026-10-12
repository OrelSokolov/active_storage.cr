# Oracle spec: Blob#signed_id — the Crystal port must reproduce
# oracle/expected_signed_id.yml exactly (captured from activestorage
# 8.1.4 via oracle/cases_signed_id.rb; verifier configured like a Rails
# 8.1 app wires ActiveStorage.verifier, fixed secret, SHA256, url_safe).
# Same case IDs, no edits.
#
# Seeding is lazy (before_all): the shared PG test database is also used
# by the other spec files, whose fixtures must survive this file's load.

require "spec"
require "../src/active_storage_cr"

SID_EXPECTED = begin
  hash = {} of String => String
  current_id : String? = nil
  File.read("#{__DIR__}/../oracle/expected_signed_id.yml").each_line do |line|
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

SID_TEST_URL = ENV["AS_TEST_URL"]? ||
               "postgres://root@/crails_as_test?host=/var/run/postgresql"

ActiveRecord::Base.establish_connection(SID_TEST_URL)

# Fixed blob like the oracle harness (fixed id/key → deterministic signed
# values). Our table also carries updated_at (documented deviation), and
# the AR port doesn't accept an explicit pk on create — the id/key are
# pinned with a raw UPDATE instead.
SID_BLOB_HOLDER = [] of ActiveStorage::Blob

def sid_blob : ActiveStorage::Blob
  SID_BLOB_HOLDER.first
end

def b64url_decode(s : String) : String
  Base64.decode_string(s.tr("-_", "+/") + "=" * ((4 - s.size % 4) % 4))
end

SID_CASES = {
  "sid_blob"               => -> { sid_blob.signed_id },
  "sid_payload"            => -> { b64url_decode(sid_blob.signed_id.split("--").first) },
  "sid_digest_shape"       => -> {
    d = sid_blob.signed_id.split("--").last
    [d.size, !!(d =~ /\A[0-9a-f]+\z/)].inspect
  },
  "sid_data_b64url_nopad"  => -> { !!(sid_blob.signed_id.split("--").first =~ /\A[A-Za-z0-9_-]+\z/).to_s },
  "sid_find"               => -> { ActiveStorage::Blob.find_signed!(sid_blob.signed_id).id.to_s },
  "sid_find_nil"           => -> {
    r = ActiveStorage::Blob.find_signed(sid_blob.signed_id, purpose: "other")
    r.nil? ? "nil" : r.to_s
  },
  # Rails accepts the id as a STRING in the envelope too (the oracle's
  # legacy-verifier case) — find_signed! must resolve it.
  "sid_find_legacy_env"    => -> {
    legacy = ActiveStorage.verifier.generate("1234567890", purpose: "blob_id")
    found = ActiveStorage::Blob.find_signed!(legacy)
    payload = b64url_decode(legacy.split("--").first)
    [found.id, payload].inspect
  },
  "sid_tampered"           => -> { ActiveStorage::Blob.find_signed!(sid_blob.signed_id + "x") },
  "sid_wrong_secret"       => -> {
    other = ActiveSupport::MessageVerifier.new("not the secret", url_safe: true)
    r = ActiveStorage::Blob.find_signed(other.generate(1234567890_i64, purpose: "blob_id"))
    r.nil? ? "nil" : r.to_s
  },
  "sid_missing_record"     => -> {
    ActiveStorage::Blob.find_signed!(
      ActiveStorage.verifier.generate(9876543210_i64, purpose: "blob_id"))
  },
  "sid_id_1"               => -> { ActiveStorage.verifier.generate("1", purpose: "blob_id") },
  "disk_token"             => -> {
    ActiveStorage.verifier.generate(
      {"key" => "fixedkeyfixedkeyfixedkey12", "content_type" => "text/plain",
       "content_length" => 9_i64,
       "checksum" => ActiveStorage::Checksum.md5_base64("BLOB DATA"),
       "service_name" => "Local"},
      purpose: "blob_token",
      expires_at: Time.utc(2030, 1, 1))
  },
  "disk_token_payload"     => -> {
    token = ActiveStorage.verifier.generate(
      {"key" => "k", "content_type" => nil, "content_length" => 0_i64,
       "checksum" => nil, "service_name" => "Local"},
      purpose: "blob_token", expires_at: Time.utc(2030, 1, 1))
    b64url_decode(token.split("--").first)
  },
  "disk_key_payload"       => -> {
    r = ActiveStorage.verifier.verified_any(
      ActiveStorage.verifier.generate(
        {"key" => "k2", "disposition" => %(inline; filename="a.png"),
         "content_type" => "image/png", "service_name" => "Local"},
        purpose: "blob_key", expires_at: Time.utc(2030, 1, 1)),
      purpose: "blob_key")
    if r.nil?
      "nil"
    else
      plain = {} of String => String
      r.as_h.each { |k, v| plain[k] = v.as_s }
      plain.inspect
    end
  },
}

describe "active_storage signed_id oracle (activestorage 8.1.4)" do
  before_all do
    # Set here, not at load time: earlier-running spec groups (direct
    # upload) swap the global verifier, and the oracle values below are
    # pinned to this exact secret.
    ActiveStorage.verifier = ActiveSupport::MessageVerifier.new(
      "crails_signed_id_oracle_secret_0123456789abcdef", url_safe: true)
    ActiveStorage.service = ActiveStorage::DiskService.new(
      File.join(Dir.tempdir, "as_sid_spec_#{Random::Secure.hex(8)}"), "Local")
    ActiveStorage.disk_url_base = ""

    ActiveRecord::Base.connection.exec("DELETE FROM active_storage_attachments")
    ActiveRecord::Base.connection.exec("DELETE FROM active_storage_blobs")

    seed = ActiveStorage::Blob.create!({
      "key"         => ActiveStorage::Blob.generate_key,
      "filename"    => "report.txt",
      "content_type" => "text/plain",
      "metadata"    => nil,
      "service_name" => "Local",
      "byte_size"   => 9_i64,
      "checksum"    => ActiveStorage::Checksum.md5_base64("BLOB DATA"),
    })
    ActiveRecord::Base.connection.exec(
      "UPDATE active_storage_blobs SET id = 1234567890, key = 'fixedkeyfixedkeyfixedkey12' WHERE id = #{seed.id}")
    SID_BLOB_HOLDER << ActiveStorage::Blob.find(1234567890_i64)
  end

  SID_EXPECTED.each do |id, expected|
    it id do
      block = SID_CASES[id]?
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
    missing = SID_EXPECTED.keys - SID_CASES.keys
    extra = SID_CASES.keys - SID_EXPECTED.keys
    missing.should be_empty
    extra.should be_empty
  end
end
