# Direct upload HTTP layer — port of ActiveStorage::DirectUploadsController
# and ActiveStorage::DiskController (activestorage 8.1.4) on top of
# action_pack_cr.
#
# NOT required by the umbrella src/active_storage_cr.cr: it pulls in the
# whole action_pack shard, so it is opt-in — apps that want direct upload
# add `require "active_storage/controllers"` and draw
# `active_storage` inside their routes block (ActiveStorage.routes below).
#
# JSON shape mirrors the gem's direct_upload_json:
#   {id, key, filename, content_type, metadata, service_name, byte_size,
#    checksum, created_at, signed_id,
#    direct_upload: {url, headers}}
#
# Deviations (documented in PLAN.md): single global service instead of
# `Blob.services` registry (service_name in tokens is carried but not
# dispatched on); relative Disk URLs unless ActiveStorage.disk_url_base
# is set (the gem uses ActiveStorage::Current.url_options).

require "action_pack_cr"

module ActiveStorage
  class BaseController < ActionController::Base
    # The gem's ApplicationController-equivalent: no CSRF protection
    # (skip_forgery_protection in the gem).
  end

  class DirectUploadsController < BaseController
    def create
      blob = ActiveStorage::Blob.create_before_direct_upload!(
        filename: blob_args["filename"].to_s,
        byte_size: blob_args["byte_size"].to_s.to_i64,
        checksum: blob_args["checksum"].to_s,
        content_type: blob_args["content_type"]?.try(&.to_s))
      render json: direct_upload_json(blob)
    end

    private def blob_args
      params.require(:blob).permit(:filename, :byte_size, :checksum,
        :content_type).to_h
    end

    private def direct_upload_json(blob : Blob) : String
      String.build do |io|
        io << "{"
        {"key"         => blob.key.to_s,
         "filename"    => blob.filename.to_s,
         "content_type" => blob.content_type.to_s,
         "metadata"    => "null",
         "service_name" => blob.service_name.to_s,
         "checksum"    => blob.checksum.to_s}.each_with_index do |(k, v), i|
          io << "," if i > 0
          k.to_json(io)
          io << ":"
          v.to_json(io)
        end
        # numbers (as_json renders integer columns as JSON numbers)
        io << ",\"id\":" << blob.id.to_s
        io << ",\"byte_size\":" << blob.byte_size.to_s
        io << ",\"created_at\":" << blob.created_at.to_s.to_json
        io << ",\"signed_id\":" << blob.signed_id.to_json
        url = blob.service_url_for_direct_upload
        headers = blob.service_headers_for_direct_upload
        io << ",\"direct_upload\":{\"url\":" << url.to_json << ",\"headers\":{"
        headers.each_with_index do |(k, v), i|
          io << "," if i > 0
          k.to_json(io)
          io << ":"
          v.to_json(io)
        end
        io << "}}}"
      end
    end
  end

  class DiskController < BaseController
    def show
      if key = decode_verified_key
        send_file ActiveStorage.service.as(DiskService)
          .path_for(key["key"].to_s),
          type: key["content_type"]?.try(&.to_s),
          filename: key["key"].to_s,
          disposition: "inline"
        return
      end
      head 404
    rescue ArgumentError # unsafe key (InvalidKeyError in the gem)
      head 404
    rescue ActionController::MissingFile
      head 404
    end

    def update
      if token = decode_verified_token
        if acceptable_content?(token)
          body = request.body.try(&.gets_to_end) || ""
          ActiveStorage.service.upload(token["key"].to_s, body,
            token["checksum"]?.try(&.to_s))
          head 204
        else
          head 422
        end
      else
        head 404
      end
    rescue ActiveStorage::IntegrityError
      head 422
    end

    private def decode_verified_key : Hash(String, String)?
      verified_payload(params["encoded_key"]?.to_s, purpose: "blob_key")
    end

    private def decode_verified_token : Hash(String, String)?
      verified_payload(params["encoded_token"]?.to_s, purpose: "blob_token")
    end

    private def verified_payload(token : String, purpose : String = "blob_token") : Hash(String, String)?
      data = ActiveStorage.verifier.verified_any(token, purpose: purpose)
      return nil unless data
      hash = {} of String => String
      data.as_h.each do |k, v|
        hash[k] = case raw = v.raw
        when String then raw
        when Nil then ""
        else raw.to_s
        end
      end
      hash
    end

    private def acceptable_content?(token : Hash(String, String)) : Bool
      return false unless (request.headers["Content-Type"]? || "") == token["content_type"]?
      (request.headers["Content-Length"]? || "") == token["content_length"]?
    end
  end

  # Route definitions for the app's `CRails.application.routes.draw` block:
  #
  #   CRails.application.routes.draw do
  #     active_storage
  #     ...
  #   end
  #
  # (`active_storage` is defined on CRails::Routes::Drawer below — the
  # draw block delegates bare calls to the drawer.)
  def self.routes : Nil
    raise NotImplementedError.new("require \"active_storage/controllers\" and call `active_storage` inside the routes draw block")
  end
end

class CRails::Routes::Drawer
  # ActiveStorage engine routes (the gem mounts these under
  # /rails/active_storage). show serves through a :blob_key-signed URL
  # (the redirect/blobs layer generates those), update consumes the
  # :blob_token-signed direct-upload URL.
  def active_storage : Nil
    post "/rails/active_storage/direct_uploads", to: "active_storage/direct_uploads#create"
    put "/rails/active_storage/disk/:encoded_token", to: "active_storage/disk#update"
    get "/rails/active_storage/disk/:encoded_key", to: "active_storage/disk#show"
  end
end
