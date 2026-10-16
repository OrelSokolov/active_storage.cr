# ActiveStorage::Blob — AR-backed blob record + upload/download/purge +
# signed_id + direct-upload helpers + Marcel-backed identification
# (`before_save :identify`, as in the gem).
# Oracle: blob_* cases (activestorage 8.1.4): MD5-base64 checksum,
# content-type predicates, key token shape [A-Za-z0-9]{24};
# sid_* / disk_* cases (oracle/cases_signed_id.rb): signed_id wire format
# (verifier data-envelope, purpose "blob_id"), disk direct-upload tokens.

module ActiveStorage
  class Blob < ActiveRecord::Base
    set_table_name "active_storage_blobs"

    KEY_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

    def self.generate_key : String
      String.build do |io|
        24.times { io << KEY_ALPHABET[Random::Secure.rand(KEY_ALPHABET.size)] }
      end
    end

    def self.create_and_upload!(io : String, filename : String,
                                content_type : String? = nil) : self
      key = generate_key
      checksum = Checksum.md5_base64(io)
      ActiveStorage.service.upload(key, io, checksum)
      create!({
        "key"      => key,
        "filename" => filename,
        # The gem's unfurl: an undeclared content type is sniffed from
        # the io via Marcel; a declared one is trusted as-is.
        "content_type" => content_type || Marcel::MimeType.for(io,
          name: filename, declared_type: nil),
        "metadata"     => nil,
        "service_name" => ActiveStorage.service_name,
        "byte_size"    => io.bytesize.to_i64,
        "checksum"     => checksum,
      })
    end

    # A saved blob WITHOUT a file on the service (the file follows via a
    # client-side direct upload to service_url_for_direct_upload).
    def self.create_before_direct_upload!(filename : String, byte_size : Int64,
                                          checksum : String,
                                          content_type : String? = nil,
                                          key : String? = nil) : self
      create!({
        "key"          => (key || generate_key),
        "filename"     => filename,
        "content_type" => content_type,
        "metadata"     => nil,
        "service_name" => ActiveStorage.service_name,
        "byte_size"    => byte_size,
        "checksum"     => checksum,
      })
    end

    # Signed reference safe to expose client-side (direct-upload round
    # trip: the browser submits this instead of the file).
    def signed_id : String
      ActiveStorage.verifier.generate(id.not_nil!, purpose: "blob_id")
    end

    def self.find_signed(signed_id : String,
                         purpose : String = "blob_id") : self?
      data = ActiveStorage.verifier.verified_any(signed_id, purpose: purpose)
      return nil unless data
      id = data.as_i64? || data.as_s?.try(&.to_i64?)
      return nil unless id
      find?(id)
    end

    # Неверная подпись/purpose → MessageVerifier::InvalidSignature (как в
    # Rails); верная подпись без записи → RecordNotFound.
    def self.find_signed!(signed_id : String,
                          purpose : String = "blob_id") : self
      data = ActiveStorage.verifier.verified_any(signed_id, purpose: purpose)
      unless data
        raise ActiveSupport::MessageVerifier::InvalidSignature.new(signed_id)
      end
      id = data.as_i64? || data.as_s?.try(&.to_i64?)
      unless id
        raise ActiveSupport::MessageVerifier::InvalidSignature.new(signed_id)
      end
      find(id)
    end

    # URL the client PUTs the file to (presigned for cloud services,
    # verifier-tokened for Disk).
    def service_url_for_direct_upload(expires_in : Int32 =
                                      ActiveStorage.service_urls_expire_in) : String
      ActiveStorage.service.url_for_direct_upload(
        key.not_nil!, expires_in: expires_in, content_type: content_type,
        content_length: byte_size.not_nil!, checksum: checksum)
    end

    def service_headers_for_direct_upload : Hash(String, String)
      ActiveStorage.service.headers_for_direct_upload(
        key.not_nil!, content_type: content_type, content_length: byte_size.not_nil!,
        checksum: checksum, filename: filename.to_s)
    end

    def download : String
      ActiveStorage.service.download(key.not_nil!)
    end

    # Rails: `before_save :identify, if: :unidentified?` — a blob saved
    # without a declared content type gets one from its magic bytes
    # (Marcel::MimeType.for(download, name:, declared_type:)).
    before_save :identify

    def identify : Nil
      unless identified?
        self.content_type = identify_content_type
      end
    end

    # The gem has no `identified` column either: presence of the
    # content_type column is the flag.
    def identified? : Bool
      !content_type.to_s.empty?
    end

    def unidentified? : Bool
      !identified?
    end

    private def identify_content_type : String
      Marcel::MimeType.for(download, name: filename.to_s,
        declared_type: content_type)
    end

    def purge : Nil
      Attachment.where("blob_id = ?", id.not_nil!).to_a.each(&.destroy)
      destroy
      ActiveStorage.service.delete(key.not_nil!)
    end

    def text? : Bool
      content_type.to_s.starts_with?("text/")
    end

    def image? : Bool
      content_type.to_s.starts_with?("image/")
    end

    def video? : Bool
      content_type.to_s.starts_with?("video/")
    end

    def audio? : Bool
      content_type.to_s.starts_with?("audio/")
    end
  end

  class Attachment < ActiveRecord::Base
    set_table_name "active_storage_attachments"

    def blob : Blob
      Blob.find(blob_id.not_nil!)
    end
  end
end
