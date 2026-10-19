# Services: abstract base + Disk implementation + the global service
# accessor. `ActiveStorage.service` plays the role of the Rails service
# registry for P0 (one named service; S3 lives in s3_service.cr).

require "openssl"

module ActiveStorage
  class IntegrityError < Exception; end

  class FileNotFoundError < Exception; end

  module Checksum
    # Ruby: Digest::MD5.base64digest(data)
    def self.md5_base64(data : String | Bytes) : String
      Base64.strict_encode(OpenSSL::Digest.new("MD5").update(data).final)
    end
  end

  # Port of ActiveStorage::Service (the gem's abstract service API).
  abstract class Service
    # Registry name (the key under storage.yml / Blob.services).
    def initialize(@name : String)
    end

    attr_reader name : String

    abstract def upload(key : String, data : String | Bytes, checksum : String? = nil, content_type : String? = nil) : Nil
    abstract def download(key : String) : String
    abstract def exist?(key : String) : Bool
    abstract def delete(key : String) : Nil

    # Presigned/public URL; the Disk service needs the app's routes and
    # raises instead (the gem routes through the redirect controller).
    def url(key : String, expires_in : Int32 = 300,
            disposition : String? = nil, filename : String? = nil,
            content_type : String? = nil) : String
      raise NotImplementedError.new("#{self.class}#url")
    end

    # URL the client directly uploads the file to. Overridden by the
    # concrete services (Disk: verifier token; S3: presigned PUT).
    def url_for_direct_upload(key : String, expires_in : Int32,
                              content_type : String?, content_length : Int64,
                              checksum : String?) : String
      raise NotImplementedError.new("#{self.class}#url_for_direct_upload")
    end

    # Headers the client must send with the direct-upload request.
    def headers_for_direct_upload(key : String, content_type : String?,
                                  content_length : Int64,
                                  checksum : String?,
                                  filename : String? = nil) : Hash(String, String)
      {} of String => String
    end
  end

  class DiskService < Service
    def initialize(@root : String, name : String = "Local")
      super(name)
      Dir.mkdir_p(@root)
    end

    def upload(key : String, data : String | Bytes, checksum : String? = nil,
               content_type : String? = nil) : Nil
      path = path_for(key)
      Dir.mkdir_p(File.dirname(path))
      File.write(path, data)
      if checksum && Checksum.md5_base64(data) != checksum
        delete(key)
        raise IntegrityError.new("checksum mismatch for #{key}")
      end
    end

    def download(key : String) : String
      File.read(path_for(key))
    end

    def exist?(key : String) : Bool
      File.exists?(path_for(key))
    end

    def delete(key : String) : Nil
      File.delete(path_for(key))
    rescue File::NotFoundError
    end

    # Public: the DiskController serves files through this (the gem's
    # `named_disk_service(key[:service_name]).path_for`).
    def path_for(key : String) : String
      raise ArgumentError.new("unsafe key: #{key}") if key.includes?("..")
      File.join(@root, key)
    end

    # Verifier-signed token riding in the URL; DiskController#update
    # verifies it (purpose "blob_token") before writing the file.
    def url_for_direct_upload(key : String, expires_in : Int32,
                              content_type : String?, content_length : Int64,
                              checksum : String?) : String
      token = ActiveStorage.verifier.generate(
        {
          "key"            => key,
          "content_type"   => content_type,
          "content_length" => content_length,
          "checksum"       => checksum,
          "service_name"   => name,
        },
        purpose: "blob_token",
        expires_in: expires_in.seconds
      )
      "#{ActiveStorage.disk_url_base}/rails/active_storage/disk/#{token}"
    end

    def headers_for_direct_upload(key : String, content_type : String?,
                                  content_length : Int64,
                                  checksum : String?,
                                  filename : String? = nil) : Hash(String, String)
      {"Content-Type" => content_type.to_s}
    end
  end

  class_property service : Service = DiskService.new(File.join(Dir.tempdir, "active_storage_cr"))

  # The blob_id/token verifier (the gem wires
  # `Rails.application.message_verifier("ActiveStorage")` — SHA256,
  # url_safe, JSON serializer). Secret: CRAILS_SECRET_KEY_BASE (the app's
  # secret_key_base) with a fixed development fallback.
  class_property verifier : ActiveSupport::MessageVerifier =
    ActiveSupport::MessageVerifier.new(
      ENV["CRAILS_SECRET_KEY_BASE"]? || "crails_active_storage_development_secret",
      url_safe: true
    )

  # ActiveStorage.service_urls_expire_in (5 minutes in the gem).
  class_property service_urls_expire_in : Int32 = 300

  # Base URL for Disk direct-upload/service URLs (the gem builds absolute
  # URLs from ActiveStorage::Current.url_options; the port keeps it a
  # class property — empty means path-only URLs).
  class_property disk_url_base : String = ""

  def self.service_name : String
    service.name
  end

  # The gem's Service#content_disposition_with →
  # ActionDispatch::Http::ContentDisposition.format (inline default):
  # `inline; filename="<sanitized>"; filename*=UTF-8''<sanitized>`
  def self.content_disposition_with(filename : String,
                                    disposition : String = "inline") : String
    sanitized = ActiveStorage::Filename.new(filename).sanitized
    %(#{disposition}; filename="#{sanitized}"; filename*=UTF-8''#{sanitized})
  end
end
