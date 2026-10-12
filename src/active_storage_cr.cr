# active_storage_cr — Crystal port of ActiveStorage 8.1.4 (Iteration 5,
# P0: Disk service, Blob/Attachment records, has_one_attached, purge).
require "active_support_cr"
require "active_record_cr"

require "./filename"
require "./service"
require "./s3_service"
require "./blob"
require "./variation"
require "./variant"
require "./attached"

module ActiveStorage
  VERSION = "0.1.0"
end
