# Oracle cases for ActiveStorage signed_id (direct-upload iteration).
#
# Run against the ORIGINAL gem:
#   ruby oracle/cases_signed_id.rb > oracle/expected_signed_id.yml
#
# Each line: "<case_id>\t<value>". Mirrored 1:1 in spec/signed_id_spec.cr.
#
# The verifier is configured exactly like a Rails 8.1 application wires
# ActiveStorage.verifier (railties: message_serializer :json_allow_marshal,
# digest SHA256, url_safe true) but with a FIXED secret so the signed
# values are deterministic. Both metadata envelope formats are captured:
# the Rails 8.1 default (`{"_rails":{"data":...}}`) and the standalone
# legacy one (`{"_rails":{"message":...,"exp":null,...}}`) — Rails accepts
# both on verify, and so must the port.

gem "activestorage", "= 8.1.4"
gem "activerecord", "= 8.1.4"
gem "activesupport", "= 8.1.4"
gem "sqlite3", ">= 2.1"
require "active_storage"
require "active_support/messages/metadata"
require "base64"
require "digest"

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
require "tmpdir"

ROOT = Dir.mktmpdir("as_oracle_sid")
ActiveStorage::Blob.services = ActiveStorage::Service::Registry.new(
  {"Local" => {"service" => "Disk", "root" => ROOT}}
)
ActiveStorage::Blob.service = ActiveStorage::Blob.services.fetch("Local")

SECRET = "crails_signed_id_oracle_secret_0123456789abcdef"
ActiveStorage.verifier = ActiveSupport::MessageVerifier.new(
  SECRET, digest: "SHA256", serializer: :json_allow_marshal, url_safe: true
)
# Rails 8.1 load_defaults: the message serializer is used for the metadata
# envelope too (`{"_rails":{"data":...}}`). The standalone gem default is
# the legacy `{"_rails":{"message":...}}` envelope — captured separately
# below via LEGACY verifier.
ActiveSupport::Messages::Metadata.use_message_serializer_for_metadata = true

BLOB = ActiveStorage::Blob.create!(
  id: 1234567890,
  key: "fixedkeyfixedkeyfixedkey12",
  filename: "report.txt",
  content_type: "text/plain",
  metadata: nil,
  service_name: "Local",
  byte_size: 9,
  checksum: Digest::MD5.base64digest("BLOB DATA"),
  created_at: Time.utc(2026, 1, 1, 0, 0, 0)
)

LEGACY = ActiveSupport::MessageVerifier.new(
  SECRET, digest: "SHA256", serializer: :json_allow_marshal, url_safe: true
)

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

# --- signed_id (Rails 8.1 app format: data envelope) -------------------
SID = BLOB.signed_id
case_run("sid_blob")         { SID }
case_run("sid_payload")      { Base64.urlsafe_decode64(SID.split("--").first) }
case_run("sid_digest_shape") { [SID.split("--").last.length, !!(SID.split("--").last =~ /\A[0-9a-f]+\z/)] }
case_run("sid_data_b64url_nopad") { !!(SID.split("--").first =~ /\A[A-Za-z0-9_-]+\z/) }
case_run("sid_find")         { ActiveStorage::Blob.find_signed!(SID).id }
case_run("sid_find_nil")     { ActiveStorage::Blob.find_signed(SID, purpose: :other) }
case_run("sid_find_legacy_env") do
  # a token generated with the standalone/legacy metadata envelope must
  # still verify (Rails accepts both envelope formats)
  legacy_sid = LEGACY.generate(BLOB.id.to_s, purpose: "blob_id")
  [ActiveStorage::Blob.find_signed!(legacy_sid).id,
   Base64.urlsafe_decode64(legacy_sid.split("--").first)]
end
case_run("sid_tampered") do
  ActiveStorage::Blob.find_signed!(SID.sub(/\.$/, "") + "x")
end
case_run("sid_wrong_secret") do
  other = ActiveSupport::MessageVerifier.new(
    "not the secret", digest: "SHA256", serializer: :json_allow_marshal, url_safe: true)
  ActiveStorage::Blob.find_signed(other.generate(BLOB.id.to_s, purpose: "blob_id"))
end
case_run("sid_missing_record") do
  ActiveStorage::Blob.find_signed!(
    ActiveStorage.verifier.generate("9876543210", purpose: "blob_id")
  )
end
case_run("sid_id_1") do
  ActiveStorage.verifier.generate("1", purpose: "blob_id")
end

# --- disk direct-upload token (purpose blob_token, Hash payload) -------
case_run("disk_token") do
  ActiveStorage.verifier.generate(
    { key: "fixedkeyfixedkeyfixedkey12", content_type: "text/plain",
      content_length: 9, checksum: Digest::MD5.base64digest("BLOB DATA"),
      service_name: "Local" },
    expires_at: Time.utc(2030, 1, 1, 0, 0, 0), purpose: :blob_token
  )
end
case_run("disk_token_payload") do
  token = ActiveStorage.verifier.generate(
    { key: "k", content_type: nil, content_length: 0, checksum: nil,
      service_name: "Local" },
    expires_at: Time.utc(2030, 1, 1, 0, 0, 0), purpose: :blob_token
  )
  Base64.urlsafe_decode64(token.split("--").first)
end
case_run("disk_key_payload") do
  ActiveStorage.verifier.verified(
    ActiveStorage.verifier.generate(
      { key: "k2", disposition: "inline; filename=\"a.png\"",
        content_type: "image/png", service_name: "Local" },
      expires_at: Time.utc(2030, 1, 1, 0, 0, 0), purpose: :blob_key
    ),
    purpose: :blob_key
  ).inspect
end
