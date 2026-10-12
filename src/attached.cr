# Attached::One / Attached::Many — the has_one_attached /
# has_many_attached proxies, and the macros that wire them into
# ActiveRecord models.
#
# Oracle: oracle/cases.rb (has_one_attached, activestorage 8.1.4),
# oracle/cases_many.rb (has_many_attached: attach single/array/blob,
# order = insertion order (created_at, id), detach keeps blobs, purge).

module ActiveStorage
  module Attached
    class One
      @cached_attachment : Attachment?

      def initialize(@name : String, @record : ActiveRecord::Base)
      end

      def attach(io : String, filename : String, content_type : String) : Blob
        detach if attached?
        blob = Blob.create_and_upload!(io: io, filename: filename, content_type: content_type)
        @cached_attachment = Attachment.create({
          "name"        => @name,
          "record_type" => @record.class.name.to_s,
          "record_id"   => @record.id.not_nil!,
          "blob_id"     => blob.id.not_nil!,
        })
        blob
      end

      def attached? : Bool
        find_attachment != nil
      end

      def blob : Blob?
        find_attachment.try { |a| Blob.find(a.blob_id.not_nil!) }
      end

      def download : String
        blob.not_nil!.download
      end

      def variant(**options)
        blob.not_nil!.variant(**options)
      end

      def url(expires_in : Int32 = 300) : String
        blob.not_nil!.url(expires_in: expires_in)
      end

      def filename : String
        blob.not_nil!.filename.not_nil!
      end

      def detach : Nil
        find_attachment.try(&.destroy)
        @cached_attachment = nil
      end

      def purge : Nil
        if a = find_attachment
          Blob.find(a.blob_id.not_nil!).purge
        end
        @cached_attachment = nil
      end

      private def find_attachment : Attachment?
        @cached_attachment ||= Attachment.find_by(
          name: @name,
          record_type: @record.class.name.to_s,
          record_id: @record.id.not_nil!
        )
      end
    end

    # The has_many_attached proxy. Collection methods (map/each/size/…)
    # go straight to the attachment rows — the port's equivalent of the
    # gem's delegate_missing_to :attachments for the collection case.
    class Many
      include Enumerable(Attachment)

      @cached_attachments : Array(Attachment)?

      def initialize(@name : String, @record : ActiveRecord::Base)
      end

      def each(&) : Nil
        attachments.each { |attachment| yield attachment }
      end

      # Attaches one attachable or several at once. An attachable is an
      # io/filename/content_type triple, an existing Blob, or a blob's
      # signed_id (the direct-upload form: the blob was created and
      # uploaded before the form was submitted).
      def attach(io : String, filename : String, content_type : String) : Nil
        attach_attachables([{io, filename, content_type}])
      end

      def attach(attachables : Array(Blob | String)) : Nil
        attach_attachables(attachables)
      end

      def attach(blob : Blob) : Nil
        attach_attachables([blob])
      end

      def attach(signed_id : String) : Nil
        attach_attachables([signed_id])
      end

      def attach(io_triplets : Array(Tuple(String, String, String))) : Nil
        attach_attachables(io_triplets)
      end

      def attachments : Array(Attachment)
        @cached_attachments ||= Attachment.where(
          name: @name,
          record_type: @record.class.name.to_s,
          record_id: @record.id.not_nil!
        ).order("created_at", "id").to_a
      end

      def blobs : Array(Blob)
        attachments.map(&.blob)
      end

      def attached? : Bool
        !attachments.empty?
      end

      # Drops the attachment rows; blobs (and their service files) stay.
      def detach : Nil
        attachments.each(&.destroy)
        @cached_attachments = nil
      end

      # Destroys the blobs (with their attachment rows and service files).
      def purge : Nil
        blobs.each(&.purge)
        @cached_attachments = nil
      end

      def download : Array(String)
        blobs.map(&.download)
      end

      private def attach_attachables(attachables) : Nil
        attachables.each do |attachable|
          blob = case attachable
          when Tuple(String, String, String)
            io, filename, content_type = attachable
            Blob.create_and_upload!(io: io, filename: filename, content_type: content_type)
          when Blob then attachable
          when String
            Blob.find_signed!(attachable)
          else
            raise ArgumentError.new("unsupported attachable: #{attachable.class}")
          end
          Attachment.create({
            "name"        => @name,
            "record_type" => @record.class.name.to_s,
            "record_id"   => @record.id.not_nil!,
            "blob_id"     => blob.id.not_nil!,
          })
        end
        @cached_attachments = nil
      end
    end
  end
end

# Wire the DSL into AR models (the gem does this via a railtie).
class ActiveRecord::Base
  macro has_one_attached(name)
    @as_attached_{{name.id}} : ActiveStorage::Attached::One?

    def {{name.id}} : ActiveStorage::Attached::One
      @as_attached_{{name.id}} ||= ActiveStorage::Attached::One.new({{name.stringify}}, self)
    end

    def {{name.id}}_blob : ActiveStorage::Blob?
      {{name.id}}.blob
    end
  end

  macro has_many_attached(name)
    @as_attached_{{name.id}} : ActiveStorage::Attached::Many?

    def {{name.id}} : ActiveStorage::Attached::Many
      @as_attached_{{name.id}} ||= ActiveStorage::Attached::Many.new({{name.stringify}}, self)
    end

    def {{name.id}}_attachments : Array(ActiveStorage::Attachment)
      {{name.id}}.attachments
    end

    def {{name.id}}_blobs : Array(ActiveStorage::Blob)
      {{name.id}}.blobs
    end
  end
end
