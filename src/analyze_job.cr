# Port of ActiveStorage::AnalyzeJob (activestorage 8.1.4 app/jobs/
# active_storage/analyze_job.rb) — opt-in like src/controllers.cr: it
# pulls in the active_job_cr shard, so it is not required by the
# umbrella src/active_storage_cr.cr. Apps that want enqueued analysis
# add:
#
#   require "active_storage/analyze_job"
#   ActiveStorage.analyze_job = ->(blob : ActiveStorage::Blob) {
#     ActiveStorage::AnalyzeJob.perform_later(blob.id.not_nil!)
#   }
#
# after which Blob#analyze_later enqueues; without wiring it performs
# inline.
#
# Deviation from the gem (documented): the job carries the blob's id,
# not the blob record — active_job_cr serializes scalars only (the gem
# uses GlobalID).

require "active_job_cr"

module ActiveStorage
  class AnalyzeJob < ActiveJob::Base
    def perform(blob_id : Int64) : Nil
      ActiveStorage::Blob.find(blob_id).analyze
    end
  end
end
