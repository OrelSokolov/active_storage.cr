# Oracle cases for ActiveStorage — S3 (MinIO) service + variants.
#
# Run against the ORIGINAL gem with a live MinIO on 127.0.0.1:9000
# (bucket "as-oracle", minioadmin/minioadmin):
#   ruby oracle/cases_s3.rb > oracle/expected_s3.yml
#
# Each line: "<case_id>\t<value>". Mirrored 1:1 in spec/s3_spec.cr.
# The Crystal port must reproduce expected_s3.yml exactly against the
# SAME MinIO instance.
#
# Notes on normalization:
# - Presigned URLs are not byte-stable (timestamps/signature) — cases
#   capture shapes/predicates (signature param present, fetch status).
# - Variant outputs are produced by different vips pipelines in the
#   port (CLI shell-out), so cases capture dimensions/content types,
#   not encoded byte sizes.
# - Fixture: oracle/fixtures/cat.png (300x180, generated via `vips
#   black`), read by both harnesses — input bytes are identical.

gem "activestorage", "= 8.1.4"
gem "activerecord", "= 8.1.4"
gem "activesupport", "= 8.1.4"
gem "sqlite3", ">= 2.1"
gem "aws-sdk-s3", "~> 1.100"
require "active_storage"
require "digest"
require "net/http"
require "uri"
require "tmpdir"
require "securerandom"

# Standalone (no railtie) — same loader as oracle/cases.rb.
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
require "#{AS_GEM}/app/models/active_storage/variation.rb"
require "#{AS_GEM}/app/models/active_storage/variant.rb"
require "#{AS_GEM}/app/models/active_storage/preview.rb"

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
  end
  create_table :active_storage_attachments do |t|
    t.string   :name,         null: false
    t.string   :record_type,  null: false
    t.integer  :record_id,    null: false
    t.integer  :blob_id,      null: false
    t.datetime :created_at,   null: false
  end
  create_table :users
end

class User < ActiveRecord::Base
  has_one_attached :avatar
end

require "active_storage/service"
require "active_storage/service/s3_service"
require "active_storage/service/registry"

ENDPOINT  = ENV.fetch("AS_S3_ENDPOINT", "http://127.0.0.1:9000")
BUCKET    = ENV.fetch("AS_S3_BUCKET", "as-oracle")
ACCESS    = ENV.fetch("AS_S3_ACCESS_KEY", "minioadmin")
SECRET    = ENV.fetch("AS_S3_SECRET_KEY", "minioadmin")

# The engine normally picks the transformer from config — standalone we
# wire the vips one by hand (Rails 8 defaults to vips on the engine),
# plus the engine's content-type lists.
ActiveStorage.variant_processor = :vips
require "active_storage/transformers/vips"
ActiveStorage.variant_transformer = ActiveStorage::Transformers::Vips
ActiveStorage.variable_content_types = %w[
  image/png image/gif image/jpeg image/tiff image/bmp
  image/vnd.adobe.photoshop image/vnd.microsoft.icon
  image/webp image/avif image/heic image/heif
]
# The railtie normally wires a MessageVerifier from the app secret.
require "active_support/message_verifier"
ActiveStorage.verifier = ActiveSupport::MessageVerifier.new("oracle-harness-secret")

ActiveStorage::Blob.services = ActiveStorage::Service::Registry.new({
  "Minio" => {
    "service" => "S3",
    "bucket" => BUCKET,
    "access_key_id" => ACCESS,
    "secret_access_key" => SECRET,
    "region" => "us-east-1",
    "endpoint" => ENDPOINT,
    "force_path_style" => true
  }
})
# Fetch through the registry: it assigns the service's name ("Minio"),
# which blobs copy into service_name on create.
MINIO = ActiveStorage::Blob.services.fetch("Minio")
ActiveStorage::Blob.service = MINIO

def render(v)
  case v
  when String then v
  else v.inspect
  end
end

def case_run(id)
  puts "#{id}\t#{render(yield)}"
rescue StandardError => e
  puts "#{id}\traise:#{e.class.name}"
end

def http_status(url)
  uri = URI(url)
  Net::HTTP.get_response(uri).code
end

# --- S3 service -------------------------------------------------------
PNG = File.binread(File.expand_path("fixtures/cat.png", __dir__))
SERVICE = MINIO

SERVICE.upload("svc/key1", StringIO.new("SERVICE DATA"),
               checksum: Digest::MD5.base64digest("SERVICE DATA"))

case_run("svc_exists")   { SERVICE.exist?("svc/key1") }
case_run("svc_download") { SERVICE.download("svc/key1") }
case_run("svc_missing")  { SERVICE.exist?("svc/nope") }
case_run("svc_delete")   { SERVICE.delete("svc/key1"); SERVICE.exist?("svc/key1") }
case_run("svc_download_missing") { SERVICE.download("svc/nope") }
case_run("svc_checksum_mismatch") do
  SERVICE.upload("svc/bad", StringIO.new("X"),
                 checksum: Digest::MD5.base64digest("Y"))
end
case_run("svc_binary_roundtrip") do
  SERVICE.upload("svc/bin1", StringIO.new(PNG),
                 checksum: Digest::MD5.base64digest(PNG))
  Digest::MD5.base64digest(SERVICE.download("svc/bin1")) ==
    Digest::MD5.base64digest(PNG)
end

url = SERVICE.url("svc/key1", expires_in: 300, disposition: "inline",
                  filename: ActiveStorage::Filename.new("key1.txt"),
                  content_type: "text/plain") # presigned GET
case_run("svc_url_shape") { url.start_with?("#{ENDPOINT}/#{BUCKET}/svc/key1?") && url.include?("X-Amz-Signature=") }
case_run("svc_url_fetch") do
  SERVICE.upload("svc/url1", StringIO.new("URL DATA"))
  uri = URI(SERVICE.url("svc/url1", expires_in: 300, disposition: "inline",
                        filename: ActiveStorage::Filename.new("url1.txt"),
                        content_type: "text/plain"))
  resp = Net::HTTP.get_response(uri)
  "#{resp.code}:#{resp.body}"
end
case_run("svc_url_expired") do
  SERVICE.upload("svc/url2", StringIO.new("TTL DATA"))
  uri = URI(SERVICE.url("svc/url2", expires_in: 1, disposition: "inline",
                        filename: ActiveStorage::Filename.new("url2.txt"),
                        content_type: "text/plain"))
  sleep 2
  http_status(uri.to_s)
end

# --- blob on S3 --------------------------------------------------------
BLOB = ActiveStorage::Blob.create_and_upload!(
  io: StringIO.new(PNG),
  filename: "cat.png",
  content_type: "image/png",
  service_name: "Minio"
)

case_run("blob_service_name") { BLOB.service_name }
case_run("blob_byte_size")    { BLOB.byte_size == PNG.bytesize }
case_run("blob_key_shape")    { BLOB.key.match?(/\A[A-Za-z0-9]{20,30}\z/) }
case_run("blob_download") do
  Digest::MD5.base64digest(BLOB.download) == Digest::MD5.base64digest(PNG)
end
case_run("blob_representable?") { BLOB.representable? }

# --- variants ----------------------------------------------------------
VARIANT = BLOB.variant(resize_to_limit: [100, 100])

case_run("var_key_format") do
  VARIANT.key.match?(/\Avariants\/#{BLOB.key}\/[0-9a-f]{64}\z/)
end
case_run("var_unprocessed") { SERVICE.exist?(VARIANT.key) }
case_run("var_content_type") { VARIANT.content_type }
case_run("var_filename") { VARIANT.filename.to_s }

VARIANT.processed

def dimensions(data)
  require "vips"
  img = Vips::Image.new_from_buffer(data, "")
  "#{img.width}x#{img.height}"
end

case_run("var_processed") { SERVICE.exist?(VARIANT.key) }
case_run("var_dimensions") { dimensions(VARIANT.download) }
case_run("var_smaller") { VARIANT.download.bytesize < PNG.bytesize }
case_run("var_url_shape") do
  VARIANT.url(expires_in: 300).match?(/\/#{BUCKET}\/#{Regexp.escape(VARIANT.key)}\?.*X-Amz-Signature=[0-9a-f]+/)
end
case_run("var_url_fetch") { http_status(VARIANT.url(expires_in: 300)) }

case_run("var_fill_dimensions") do
  v = BLOB.variant(resize_to_fill: [64, 64]).processed
  dimensions(v.download)
end
case_run("var_rotate_dimensions") do
  v = BLOB.variant(rotate: 90).processed
  dimensions(v.download)
end
case_run("var_format_content_type") do
  v = BLOB.variant(resize_to_limit: [50, 50], format: "webp")
  v.content_type
end

# --- has_one_attached over S3 -------------------------------------------
USER = User.create!
USER.avatar.attach(io: StringIO.new(PNG), filename: "cat.png",
                   content_type: "image/png")

case_run("att_s3_attached") { USER.reload.avatar.attached? }
case_run("att_s3_download") do
  Digest::MD5.base64digest(USER.avatar.download) == Digest::MD5.base64digest(PNG)
end
case_run("att_s3_url_signature") do
  USER.avatar.url(expires_in: 300).include?("X-Amz-Signature=")
end
case_run("att_s3_variant") do
  dimensions(USER.avatar.variant(resize_to_limit: [10, 10]).processed.download)
end

# --- direct upload (presigned PUT) --------------------------------------
DU_DATA = "S3 DIRECT UPLOAD BYTES"
DU_BLOB = ActiveStorage::Blob.create_before_direct_upload!(
  filename: "racecar.bin", byte_size: DU_DATA.bytesize,
  checksum: Digest::MD5.base64digest(DU_DATA), content_type: "application/octet-stream"
)
DU_URL = DU_BLOB.service_url_for_direct_upload
DU_HEADERS = DU_BLOB.service_headers_for_direct_upload

case_run("s3du_blob_row") do
  [DU_BLOB.persisted?, ActiveStorage::Blob.service.exist?(DU_BLOB.key),
   DU_BLOB.byte_size == DU_DATA.bytesize]
end
case_run("s3du_url_shape") do
  uri = URI(DU_URL)
  query = URI.decode_www_form(uri.query.to_s).to_h
  [uri.path == "/#{BUCKET}/#{DU_BLOB.key}",
   query["X-Amz-Algorithm"],
   query["X-Amz-SignedHeaders"],
   !!DU_URL.include?("X-Amz-Signature="),
   query["X-Amz-Expires"]]
end
case_run("s3du_headers") { DU_HEADERS }

def presigned_put(url, headers, body)
  uri = URI(url)
  req = Net::HTTP::Put.new(uri)
  headers.each { |k, v| req[k] = v }
  req.body = body
  Net::HTTP.start(uri.host, uri.port) { |http| http.request(req).code }
end

case_run("s3du_put_status") do
  presigned_put(DU_URL, DU_HEADERS, DU_DATA)
end
case_run("s3du_roundtrip") do
  Digest::MD5.base64digest(DU_BLOB.download) == Digest::MD5.base64digest(DU_DATA)
end
case_run("s3du_put_bad_checksum") do
  url = DU_BLOB.service_url_for_direct_upload
  headers = DU_BLOB.service_headers_for_direct_upload
  presigned_put(url, headers, "TAMPERED")
end
