# S3 (MinIO) + variants oracle spec: the Crystal port must reproduce
# oracle/expected_s3.yml exactly (captured from activestorage 8.1.4
# against a live MinIO — see oracle/cases_s3.rb). Same case IDs, no
# edits; runs against the same MinIO instance (default bucket
# "as-crystal" to keep oracle/port objects separate).
#
# Requires: MinIO on 127.0.0.1:9000 (minioadmin/minioadmin) with the
# bucket created; `vips` on PATH. Skips with a notice when MinIO is
# not reachable so `crystal spec` stays green without docker.

require "spec"
require "http/client"
require "process"
require "../src/active_storage_cr"

EXPECTED_S3 = begin
  hash = {} of String => String
  current_id : String? = nil
  File.read("#{__DIR__}/../oracle/expected_s3.yml").each_line do |line|
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

ENDPOINT = ENV["AS_S3_ENDPOINT"]? || "http://127.0.0.1:9000"
BUCKET   = ENV["AS_S3_BUCKET"]? || "as-crystal"

def minio_reachable? : Bool
  uri = URI.parse(ENDPOINT)
  sock = TCPSocket.new(uri.host.not_nil!, uri.port.not_nil!, connect_timeout: 1)
  sock.close
  true
rescue Socket::Error | IO::Error
  false
end

def as_http_status(url : String) : String
  HTTP::Client.get(URI.parse(url)).status.code.to_s
end

# vips dimensions of raw image bytes ("300x180").
def as_dimensions(data : String) : String
  tmp = File.join(Dir.tempdir, "as_spec_#{Random::Secure.hex(6)}.png")
  File.write(tmp, data)
  buf = IO::Memory.new
  Process.run("vipsheader", [tmp], output: buf)
  File.delete(tmp) rescue nil
  if m = buf.to_s.match(/(\d+)x(\d+)/)
    "#{m[1]}x#{m[2]}"
  else
    "vipsheader-failed"
  end
end

class User < ActiveRecord::Base
  has_one_attached :avatar
end

# Fixture holders: created lazily in the describe's before_all (other
# spec groups run first and wipe the tables, which would destroy
# load-time fixtures before this group's examples get their turn).
VARIANT_BLOB_HOLDER = [] of ActiveStorage::Blob
VARIANT_HOLDER      = [] of ActiveStorage::Variant
S3_USER_HOLDER      = [] of User

def s3_variant_blob : ActiveStorage::Blob
  VARIANT_BLOB_HOLDER.first
end

def s3_variant : ActiveStorage::Variant
  VARIANT_HOLDER.first
end

def s3_user : User
  S3_USER_HOLDER.first
end

S3DU_DATA = "S3 DIRECT UPLOAD BYTES"
S3_DU_BLOB_HOLDER = [] of ActiveStorage::Blob

def s3_du_blob : ActiveStorage::Blob
  S3_DU_BLOB_HOLDER.first
end

# PUT with the direct-upload headers (Content-Length is signed too —
# HTTP::Client sets it from the body, which matches the blob's
# byte_size in the direct-upload flow).
def presigned_put(url : String, headers : Hash(String, String), body : String) : Int32
  uri = URI.parse(url)
  http_headers = HTTP::Headers.new
  headers.each { |k, v| http_headers[k] = v }
  resp = HTTP::Client.put(uri, headers: http_headers, body: body)
  resp.status.code
end

if minio_reachable?
  test_url = ENV["AS_TEST_URL"]? ||
             "postgres://root@/crails_as_test?host=/var/run/postgresql"
  ActiveRecord::Base.establish_connection(test_url)
  # No table cleanup here on purpose: earlier spec files wipe the tables
  # in their own before_all blocks (after their examples ran); this
  # group's fixtures are created in its before_all below.

  service = ActiveStorage::S3Service.new(
    endpoint: ENDPOINT, bucket: BUCKET,
    access_key_id: ENV["AS_S3_ACCESS_KEY"]? || "minioadmin",
    secret_access_key: ENV["AS_S3_SECRET_KEY"]? || "minioadmin",
    region: "us-east-1", name: "Minio"
  )
  ActiveStorage.service = service

  png = File.read("#{__DIR__}/../oracle/fixtures/cat.png")

  cases = {
    "svc_exists"            => -> { service.exist?("svc/key1").to_s },
    "svc_download"          => -> { service.download("svc/key1") },
    "svc_missing"           => -> { service.exist?("svc/nope").to_s },
    "svc_delete"            => -> { service.delete("svc/key1"); service.exist?("svc/key1").to_s },
    "svc_download_missing"  => -> { service.download("svc/nope") },
    "svc_checksum_mismatch" => -> {
      service.upload("svc/bad", "X",
        checksum: ActiveStorage::Checksum.md5_base64("Y"))
    },
    "svc_binary_roundtrip" => -> {
      service.upload("svc/bin1", png,
        checksum: ActiveStorage::Checksum.md5_base64(png))
      (ActiveStorage::Checksum.md5_base64(service.download("svc/bin1")) ==
        ActiveStorage::Checksum.md5_base64(png)).to_s
    },
    "svc_url_shape" => -> {
      url = service.url("svc/key1", expires_in: 300, disposition: "inline",
        filename: "key1.txt", content_type: "text/plain")
      (url.starts_with?("#{ENDPOINT}/#{BUCKET}/svc/key1?") &&
        url.includes?("X-Amz-Signature=")).to_s
    },
    "svc_url_fetch" => -> {
      service.upload("svc/url1", "URL DATA")
      uri = URI.parse(service.url("svc/url1", expires_in: 300,
        disposition: "inline", filename: "url1.txt", content_type: "text/plain"))
      resp = HTTP::Client.get(uri)
      "#{resp.status.code}:#{resp.body}"
    },
    "svc_url_expired" => -> {
      service.upload("svc/url2", "TTL DATA")
      uri = service.url("svc/url2", expires_in: 1,
        disposition: "inline", filename: "url2.txt", content_type: "text/plain")
      sleep Time::Span.new(seconds: 2)
      as_http_status(uri.to_s)
    },
    # --- blob on S3 ---
    "blob_service_name"   => -> { s3_variant_blob.service_name.to_s },
    "blob_byte_size"      => -> { (s3_variant_blob.byte_size == png.bytesize).to_s },
    "blob_key_shape"      => -> { !!(s3_variant_blob.key =~ /\A[A-Za-z0-9]{20,30}\z/).to_s },
    "blob_download"       => -> {
      (ActiveStorage::Checksum.md5_base64(s3_variant_blob.download) ==
        ActiveStorage::Checksum.md5_base64(png)).to_s
    },
    "blob_representable?" => -> { s3_variant_blob.representable?.to_s },
    # --- variants ---
    "var_key_format"      => -> { !!(s3_variant.key =~ /\Avariants\/#{s3_variant_blob.key}\/[0-9a-f]{64}\z/).to_s },
    "var_unprocessed"     => -> {
      blob2 = ActiveStorage::Blob.create_and_upload!(io: png,
        filename: "cat2.png", content_type: "image/png")
      service.exist?(blob2.variant(resize_to_limit: [100, 100]).key).to_s
    },
    "var_content_type"    => -> { s3_variant.content_type },
    "var_filename"        => -> { s3_variant.filename.to_s },
    "var_processed"       => -> { service.exist?(s3_variant.key).to_s },
    "var_dimensions"      => -> { as_dimensions(s3_variant.download) },
    "var_smaller"         => -> { (s3_variant.download.bytesize < png.bytesize).to_s },
    "var_url_shape"       => -> {
      url = s3_variant.url(expires_in: 300)
      (url.includes?("/#{BUCKET}/#{s3_variant.key}") &&
        url.includes?("X-Amz-Signature=")).to_s
    },
    "var_url_fetch"       => -> { as_http_status(s3_variant.url(expires_in: 300)) },
    "var_fill_dimensions" => -> {
      v = s3_variant_blob.variant(resize_to_fill: [64, 64]).processed
      as_dimensions(v.download)
    },
    "var_rotate_dimensions" => -> {
      v = s3_variant_blob.variant(rotate: 90).processed
      as_dimensions(v.download)
    },
    "var_format_content_type" => -> {
      s3_variant_blob.variant(resize_to_limit: [50, 50], format: "webp").content_type
    },
    # --- has_one_attached over S3 ---
    "att_s3_attached"      => -> { s3_user.avatar.attached?.to_s },
    "att_s3_download"      => -> {
      (ActiveStorage::Checksum.md5_base64(s3_user.avatar.download) ==
        ActiveStorage::Checksum.md5_base64(png)).to_s
    },
    "att_s3_url_signature" => -> {
      s3_user.avatar.url(expires_in: 300).includes?("X-Amz-Signature=").to_s
    },
    "att_s3_variant"       => -> {
      as_dimensions(s3_user.avatar.variant(resize_to_limit: [10, 10]).processed.download)
    },
    # --- direct upload (presigned PUT) ---
    "s3du_blob_row"        => -> {
      [s3_du_blob.persisted?,
       ActiveStorage.service.exist?(s3_du_blob.key.not_nil!),
       s3_du_blob.byte_size == S3DU_DATA.bytesize].inspect
    },
    "s3du_url_shape"       => -> {
      uri = URI.parse(s3_du_blob.service_url_for_direct_upload)
      query = URI::Params.parse(uri.query.to_s)
      [uri.path == "/#{BUCKET}/#{s3_du_blob.key}",
       query["X-Amz-Algorithm"]?,
       query["X-Amz-SignedHeaders"]?,
       s3_du_blob.service_url_for_direct_upload.includes?("X-Amz-Signature="),
       query["X-Amz-Expires"]?].inspect
    },
    "s3du_headers"         => -> {
      s3_du_blob.service_headers_for_direct_upload.inspect
    },
    "s3du_put_status"      => -> {
      presigned_put(
        s3_du_blob.service_url_for_direct_upload,
        s3_du_blob.service_headers_for_direct_upload,
        S3DU_DATA).to_s
    },
    "s3du_roundtrip"       => -> {
      (ActiveStorage::Checksum.md5_base64(s3_du_blob.download) ==
        ActiveStorage::Checksum.md5_base64(S3DU_DATA)).to_s
    },
    "s3du_put_bad_checksum" => -> {
      presigned_put(
        s3_du_blob.service_url_for_direct_upload,
        s3_du_blob.service_headers_for_direct_upload,
        "TAMPERED").to_s
    },
  }

  describe "active_storage S3+variants oracle (activestorage 8.1.4, MinIO)" do
    before_all do
      # Pin the global service BEFORE creating fixtures: earlier groups
      # leave it pointing at their own Disk services.
      ActiveStorage.service = service

      # The oracle harness (oracle/cases_s3.rb) pins the vips variant
      # processor before generating variant fixtures — mirror it.
      ActiveStorage.variant_processor = :vips

      # --- S3 service ---
      service.upload("svc/key1", "SERVICE DATA",
        checksum: ActiveStorage::Checksum.md5_base64("SERVICE DATA"))

      blob = ActiveStorage::Blob.create_and_upload!(
        io: png, filename: "cat.png", content_type: "image/png"
      )
      VARIANT_BLOB_HOLDER << blob
      VARIANT_HOLDER << blob.variant(resize_to_limit: [100, 100]).tap(&.processed)

      user = User.create
      user.avatar.attach(io: png, filename: "cat.png", content_type: "image/png")
      S3_USER_HOLDER << user

      S3_DU_BLOB_HOLDER << ActiveStorage::Blob.create_before_direct_upload!(
        filename: "racecar.bin", byte_size: S3DU_DATA.bytesize.to_i64,
        checksum: ActiveStorage::Checksum.md5_base64(S3DU_DATA),
        content_type: "application/octet-stream")
    end

    after_all do
      # Back to the 8.1.4 default for other groups.
      ActiveStorage.variant_processor = :mini_magick
    end

    EXPECTED_S3.each do |id, expected|
      it id do
        # Pin the global service while these cases run (the disk-oracle
        # file swaps it back for its own examples).
        ActiveStorage.service = service
        block = cases[id]?
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

    it "mirrors every S3 oracle case" do
      (EXPECTED_S3.keys - cases.keys).should be_empty
      (cases.keys - EXPECTED_S3.keys).should be_empty
    end
  end
else
  puts "↷ skipping S3 spec: no MinIO at #{ENDPOINT} (see oracle/cases_s3.rb)"
end
