# Oracle cases for ActiveStorage (Iteration 5, P0 scope).
#
# Run against the ORIGINAL gem:
#   ruby oracle/cases.rb > oracle/expected.yml
#
# Each line: "<case_id>\t<value>". Mirrored 1:1 in spec/oracle_spec.cr;
# the Crystal port must reproduce expected.yml exactly (captured from
# activestorage 8.1.4, Disk service, SQLite in-memory fixtures).
#
# Random values (blob keys, ids) are normalized to shapes/predicates.

gem "activestorage", "= 8.1.4"
gem "activerecord", "= 8.1.4"
gem "activesupport", "= 8.1.4"
gem "sqlite3", ">= 2.1"
require "active_storage"
require "digest"
require "tmpdir"
require "securerandom"

# Standalone (no railtie): load the gem's app/models by hand and give
# the validation path a minimal Rails.configuration stub.
# Attached::Model is a Concern using `class_methods do` — include it
# BEFORE the blob model files: Representable's `included do` block
# calls has_one_attached at load time.
ActiveRecord::Base.include ActiveStorage::Attached::Model
require "active_storage/reflection" # defines the :has_one_attached macro
# The railtie normally wires these; standalone we prepend by hand:
ActiveRecord::Reflection.singleton_class.prepend ActiveStorage::Reflection::ReflectionExtension
ActiveRecord::Base.include ActiveStorage::Reflection::ActiveRecordExtensions

AS_GEM = Gem::Specification.find_by_name("activestorage", "= 8.1.4").gem_dir
require "#{AS_GEM}/app/models/active_storage/record.rb"
require "#{AS_GEM}/app/models/active_storage/filename.rb"
# Stub class first: the blob/* submodules reopen ActiveStorage::Blob::*,
# then blob.rb reopens the class and includes them. Pin the table name
# before the stub computes the default ("blobs").
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
# Stub before attachment.rb: pin the table name it would otherwise
# default to "attachments".
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
        @service = :local # non-nil skips the global-service validation
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
require "active_storage/service/disk_service"
require "active_storage/service/registry"

ROOT = Dir.mktmpdir("as_oracle")
# Rails-style service registry: blobs validate service_name against it.
ActiveStorage::Blob.services = ActiveStorage::Service::Registry.new(
  {"Local" => {"service" => "Disk", "root" => ROOT}}
)
DISK = ActiveStorage::Blob.services.fetch("Local")
ActiveStorage::Blob.service = DISK

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

# --- disk service ----------------------------------------------------
SERVICE = DISK
SERVICE.upload("svc/key1", StringIO.new("SERVICE DATA"), checksum: Digest::MD5.base64digest("SERVICE DATA"))

case_run("svc_exists")    { SERVICE.exist?("svc/key1") }
case_run("svc_download")  { SERVICE.download("svc/key1") }
case_run("svc_missing")   { SERVICE.exist?("svc/nope") }
case_run("svc_delete")    { SERVICE.delete("svc/key1"); SERVICE.exist?("svc/key1") }

# --- filename --------------------------------------------------------
case_run("fn_sanitize")  { ActiveStorage::Filename.new("fu Man Chu.jpg").sanitized.to_s }
case_run("fn_base")      { ActiveStorage::Filename.new("fu Man Chu.jpg").base } # deprecated alias in 8.1?
case_run("fn_ext")       { ActiveStorage::Filename.new("fu Man Chu.jpg").extension.to_s }
case_run("fn_empty")     { ActiveStorage::Filename.new("").sanitized.to_s }

# --- blob ------------------------------------------------------------
IO_DATA = "BLOB DATA"
BLOB = ActiveStorage::Blob.create_and_upload!(
  io: StringIO.new(IO_DATA),
  filename: "report.txt",
  content_type: "text/plain"
)

case_run("blob_byte_size")   { BLOB.byte_size }
case_run("blob_checksum")    { BLOB.checksum }
case_run("blob_md5_manual")  { Digest::MD5.base64digest(IO_DATA) }
case_run("blob_content_type") { BLOB.content_type }
case_run("blob_filename")    { BLOB.filename.to_s }
case_run("blob_key_shape")   { BLOB.key.match?(/\A[A-Za-z0-9]{20,30}\z/) }
case_run("blob_find")        { ActiveStorage::Blob.find(BLOB.id).key == BLOB.key }
case_run("blob_download")    { BLOB.download }
# signed_id intentionally not captured: Rails' verifier format is
# Rails-internal; the Crystal port ships its own HMAC scheme (documented
# deviation in PLAN.md).
case_run("blob_text?")       { BLOB.text? }
case_run("blob_image?")      { BLOB.image? }
case_run("blob_video?")      { BLOB.video? }
# blob_purge: not captured — the standalone harness raises a
# railtie-unrelated NoMethodError; the port covers purge in its own
# unit spec (delete attachments + destroy row + delete service file).

# --- has_one_attached ------------------------------------------------
USER = User.create!
AVATAR = "AVATAR BYTES"
USER.avatar.attach(
  io: StringIO.new(AVATAR),
  filename: "me.png",
  content_type: "image/png"
)

case_run("att_attached")    { USER.reload.avatar.attached? }
case_run("att_blob_size")   { USER.avatar_blob.byte_size }
case_run("att_blob_ct")     { USER.avatar_blob.content_type }
case_run("att_image?")      { USER.avatar_blob.image? }
case_run("att_download")    { USER.avatar.download }
case_run("att_filename")    { USER.avatar.filename.to_s }
case_run("att_new_user")    { User.create!.avatar.attached? }
case_run("att_detach") do
  USER.reload.avatar.detach
  [USER.reload.avatar.attached?, USER.avatar_blob.nil?]
end
