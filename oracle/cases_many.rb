# Oracle cases for ActiveStorage has_many_attached (direct-upload
# iteration).
#
# Run against the ORIGINAL gem:
#   ruby oracle/cases_many.rb > oracle/expected_many.yml
#
# Each line: "<case_id>\t<value>". Mirrored 1:1 in spec/many_spec.cr.
# Same standalone bootstrap as oracle/cases.rb (activestorage 8.1.4,
# SQLite in-memory, Disk service).

gem "activestorage", "= 8.1.4"
gem "activerecord", "= 8.1.4"
gem "activesupport", "= 8.1.4"
gem "sqlite3", ">= 2.1"
require "active_storage"
require "digest"
require "tmpdir"
require "securerandom"

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
  create_table :galleries
end

class Gallery < ActiveRecord::Base
  has_many_attached :photos
end

require "active_storage/service"
require "active_storage/service/disk_service"
require "active_storage/service/registry"

ROOT = Dir.mktmpdir("as_oracle_many")
ActiveStorage::Blob.services = ActiveStorage::Service::Registry.new(
  {"Local" => {"service" => "Disk", "root" => ROOT}}
)
ActiveStorage::Blob.service = ActiveStorage::Blob.services.fetch("Local")

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

# --- has_many_attached -----------------------------------------------
GALLERY = Gallery.create!

case_run("many_attached_new")  { Gallery.create!.photos.attached? }
case_run("many_empty_count")   { GALLERY.photos.attachments.length }

# attach one at a time, then check insertion order (id order)
GALLERY.photos.attach(io: StringIO.new("ONE"),   filename: "one.png",   content_type: "image/png")
case_run("many_count_1")       { GALLERY.reload.photos.attachments.length }
GALLERY.photos.attach(io: StringIO.new("TWO"),   filename: "two.jpg",   content_type: "image/jpeg")
GALLERY.photos.attach(io: StringIO.new("THREE"), filename: "three.gif", content_type: "image/gif")

case_run("many_attached")      { GALLERY.reload.photos.attached? }
case_run("many_order")         { GALLERY.photos.map { |p| p.filename.to_s } }
case_run("many_blobs_sizes")   { GALLERY.photos.blobs.map(&:byte_size) }
case_run("many_blobs_types")   { GALLERY.photos.blobs.map(&:content_type) }
case_run("many_dl_first")      { GALLERY.photos.blobs.first.download }
case_run("many_dl_last")       { GALLERY.photos.blobs.last.download }
case_run("many_attachments_cnt") { GALLERY.reload.photos_attachments.length }
case_run("many_blobs_cnt")       { GALLERY.reload.photos_blobs.length }

# attach several at once (array of attachable hashes)
GALLERY.photos.attach([
  { io: StringIO.new("FOUR"), filename: "four.txt", content_type: "text/plain" },
  { io: StringIO.new("FIVE"), filename: "five.txt", content_type: "text/plain" }
])
case_run("many_count_5")       { GALLERY.reload.photos.map { |p| p.filename.to_s } }

# attaching an existing blob by itself (the direct-upload form: the
# blob already exists; only an attachment row is added)
BLOB = ActiveStorage::Blob.create_and_upload!(
  io: StringIO.new("SIX"), filename: "six.png", content_type: "image/png"
)
GALLERY.photos.attach(BLOB)
case_run("many_count_6")       { GALLERY.reload.photos.map { |p| p.filename.to_s } }
case_run("many_blob_shared")   { ActiveStorage::Attachment.where(blob_id: BLOB.id).count }

# detach keeps blobs
case_run("many_detach") do
  GALLERY.reload.photos.detach
  [GALLERY.reload.photos.attached?, ActiveStorage::Blob.exists?(BLOB.id)]
end

# re-attach after detach starts fresh
GALLERY.photos.attach(io: StringIO.new("SEVEN"), filename: "seven.png", content_type: "image/png")
case_run("many_reattach")      { GALLERY.reload.photos.map { |p| p.filename.to_s } }

# purge removes attachments + blobs + service files
KEYS = GALLERY.reload.photos.blobs.map(&:key)
case_run("many_purge") do
  GALLERY.reload.photos.purge
  [GALLERY.reload.photos.attached?,
   ActiveStorage::Attachment.count,
   ActiveStorage::Blob.count,
   KEYS.all? { |k| !ActiveStorage::Blob.service.exist?(k) }]
end
