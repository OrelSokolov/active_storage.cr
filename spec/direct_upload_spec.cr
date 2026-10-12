# Direct upload spec: DirectUploadsController + DiskController roundtrip
# through the action_pack dispatch layer (__set_params/__run_action — the
# pattern of action_pack.cr/spec/controllers_spec.cr). No network: the
# "PUT to the service URL" step is dispatched straight into
# DiskController#update with the token from the returned URL.
#
# Flow (as with the gem's activestorage.js):
#   1. POST /rails/active_storage/direct_uploads → blob row + JSON
#      {signed_id, direct_upload:{url, headers}}
#   2. PUT /rails/active_storage/disk/<token> with the advertised
#      Content-Type/Content-Length → 204, file lands on the Disk service
#   3. attach(signed_id) on a has_many_attached record → download round-trips
#
# The JSON payload shape (keys present, no extra top-level keys) is pinned
# against the gem's direct_upload_json (as_json + methods: :signed_id).

require "spec"
require "http"
require "json"
require "../src/active_storage_cr"
require "../src/controllers"

DU_TEST_URL = ENV["AS_TEST_URL"]? ||
              "postgres://root@/crails_as_test?host=/var/run/postgresql"

ActiveRecord::Base.establish_connection(DU_TEST_URL)

class DuGallery < ActiveRecord::Base
  set_table_name "galleries"
  has_many_attached :photos
end

DU_ROOT = File.join(Dir.tempdir, "as_du_spec_#{Random::Secure.hex(8)}")
DU_SERVICE = ActiveStorage::DiskService.new(DU_ROOT, "Local")
DU_BLOB_IDS = [] of Int64
DU_GALLERY_IDS = [] of Int64

def du_reset_service : Nil
  ActiveStorage.service = DU_SERVICE
  ActiveStorage.verifier = ActiveSupport::MessageVerifier.new(
    "direct_upload_spec_secret", url_safe: true)
  ActiveStorage.disk_url_base = ""
end

du_reset_service

# Last built context's backing IO (contexts are built and dispatched
# synchronously, so one slot is enough to read the response body back).
DU_LAST_IO = IO::Memory.new

def du_build_context(method : String, path : String, body : String? = nil,
                     content_type : String? = nil) : HTTP::Server::Context
  DU_LAST_IO.clear
  headers = HTTP::Headers.new
  if body
    headers["Content-Type"] = content_type || "application/octet-stream"
    headers["Content-Length"] = body.bytesize.to_s
  end
  request = HTTP::Request.new(method, path, headers, body)
  HTTP::Server::Context.new(request, HTTP::Server::Response.new(DU_LAST_IO))
end

def du_dispatch(context : HTTP::Server::Context, klass, action : String,
                route_params : Hash(String, String) = {} of String => String)
  du_reset_service
  controller = klass.new(context)
  controller.__set_params(route_params)
  controller.__run_action(action)
  context.response.close
  context
end

def du_response_body(context : HTTP::Server::Context) : String
  # HTTP::Server::Response writes the status line + headers into the
  # backing IO before the body — return what follows the blank line.
  raw = DU_LAST_IO.to_s
  raw.split("\r\n\r\n", 2)[1]? || ""
end

describe "ActiveStorage.routes" do
  it "draws the engine routes into a CRails route set" do
    set = CRails::Routes::RouteSet.new
    set.draw { active_storage }
    m = set.match("POST", "/rails/active_storage/direct_uploads")
    m.should_not be_nil
    m.not_nil!.route.controller.should eq("active_storage/direct_uploads")
    m.not_nil!.route.action.should eq("create")

    token = "tok"
    put_m = set.match("PUT", "/rails/active_storage/disk/#{token}")
    put_m.should_not be_nil
    put_m.not_nil!.params["encoded_token"].should eq("tok")
    put_m.not_nil!.route.controller.should eq("active_storage/disk")

    get_m = set.match("GET", "/rails/active_storage/disk/key")
    get_m.should_not be_nil
    get_m.not_nil!.params["encoded_key"].should eq("key")
  end
end

describe "ActiveStorage::DirectUploadsController" do
  it "creates a blob before direct upload and returns the wire JSON" do
    data = "DIRECT UPLOAD BYTES"
    body = {
      "blob" => {
        "filename"     => "racecar.jpg",
        "byte_size"    => data.bytesize,
        "checksum"     => ActiveStorage::Checksum.md5_base64(data),
        "content_type" => "image/jpeg",
      },
    }.to_json
    ctx = du_dispatch(
      du_build_context("POST", "/rails/active_storage/direct_uploads",
        body, "application/json"),
      ActiveStorage::DirectUploadsController, "create")

    ctx.response.status_code.should eq(200)
    ctx.response.headers["Content-Type"].should contain("application/json")

    json = JSON.parse(du_response_body(ctx))
    # gem's as_json(root: false, methods: :signed_id) — exactly these keys.
    json.as_h.keys.sort.should eq([
      "byte_size", "checksum", "content_type", "created_at", "direct_upload",
      "filename", "id", "key", "metadata", "service_name", "signed_id",
    ])
    json["filename"].as_s.should eq("racecar.jpg")
    json["byte_size"].as_i64.should eq(data.bytesize.to_i64)
    json["service_name"].as_s.should eq("Local")
    json["direct_upload"]["url"].as_s.should start_with("/rails/active_storage/disk/")
    json["direct_upload"]["headers"]["Content-Type"].as_s.should eq("image/jpeg")

    # the blob row exists, but no file on the service yet
    blob = ActiveStorage::Blob.find_signed!(json["signed_id"].as_s)
    DU_BLOB_IDS << blob.id.not_nil!
    blob.filename.should eq("racecar.jpg")
    DU_SERVICE.exist?(blob.key.not_nil!).should be_false
  end
end

describe "ActiveStorage::DiskController" do
  data = "DIRECT UPLOAD BYTES"

  it "PUT round-trips the file through the signed token URL" do
    blob = ActiveStorage::Blob.create_before_direct_upload!(
      filename: "racecar.jpg", byte_size: data.bytesize.to_i64,
      checksum: ActiveStorage::Checksum.md5_base64(data),
      content_type: "image/jpeg")
    DU_BLOB_IDS << blob.id.not_nil!

    url = blob.service_url_for_direct_upload
    url.should start_with("/rails/active_storage/disk/")
    token = url.split("/").last

    ctx = du_dispatch(
      du_build_context("PUT", url, data, "image/jpeg"),
      ActiveStorage::DiskController, "update",
      {"encoded_token" => token})
    ctx.response.status_code.should eq(204)

    blob.download.should eq(data)
    DU_SERVICE.exist?(blob.key.not_nil!).should be_true
  end

  it "rejects a checksum mismatch with 422 and drops the file" do
    blob = ActiveStorage::Blob.create_before_direct_upload!(
      filename: "bad.jpg", byte_size: data.bytesize.to_i64,
      checksum: ActiveStorage::Checksum.md5_base64("OTHER DATA"),
      content_type: "image/jpeg")
    DU_BLOB_IDS << blob.id.not_nil!

    url = blob.service_url_for_direct_upload
    token = url.split("/").last
    ctx = du_dispatch(
      du_build_context("PUT", url, data, "image/jpeg"),
      ActiveStorage::DiskController, "update",
      {"encoded_token" => token})
    ctx.response.status_code.should eq(422)
    DU_SERVICE.exist?(blob.key.not_nil!).should be_false
  end

  it "rejects a content-length mismatch with 422" do
    blob = ActiveStorage::Blob.create_before_direct_upload!(
      filename: "len.jpg", byte_size: 999_i64,
      checksum: ActiveStorage::Checksum.md5_base64(data),
      content_type: "image/jpeg")
    DU_BLOB_IDS << blob.id.not_nil!

    url = blob.service_url_for_direct_upload
    token = url.split("/").last
    ctx = du_dispatch(
      du_build_context("PUT", url, data, "image/jpeg"),
      ActiveStorage::DiskController, "update",
      {"encoded_token" => token})
    ctx.response.status_code.should eq(422)
  end

  it "rejects a content-type mismatch with 422" do
    blob = ActiveStorage::Blob.create_before_direct_upload!(
      filename: "ct.jpg", byte_size: data.bytesize.to_i64,
      checksum: ActiveStorage::Checksum.md5_base64(data),
      content_type: "image/jpeg")
    DU_BLOB_IDS << blob.id.not_nil!

    url = blob.service_url_for_direct_upload
    token = url.split("/").last
    ctx = du_dispatch(
      du_build_context("PUT", url, data, "text/plain"),
      ActiveStorage::DiskController, "update",
      {"encoded_token" => token})
    ctx.response.status_code.should eq(422)
  end

  it "answers 404 for a tampered/unsigned token" do
    ctx = du_dispatch(
      du_build_context("PUT", "/rails/active_storage/disk/bogus", data,
        "image/jpeg"),
      ActiveStorage::DiskController, "update",
      {"encoded_token" => "bogus"})
    ctx.response.status_code.should eq(404)
  end

  it "serves an uploaded file through a blob_key-signed URL" do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: "SERVED DATA", filename: "served.png", content_type: "image/png")
    DU_BLOB_IDS << blob.id.not_nil!

    encoded_key = ActiveStorage.verifier.generate(
      {"key" => blob.key.not_nil!, "disposition" => %(inline; filename="served.png"),
       "content_type" => "image/png", "service_name" => "Local"},
      purpose: "blob_key")

    ctx = du_dispatch(
      du_build_context("GET", "/rails/active_storage/disk/#{encoded_key}"),
      ActiveStorage::DiskController, "show",
      {"encoded_key" => encoded_key})
    ctx.response.status_code.should eq(200)
    ctx.response.headers["Content-Type"].should contain("image/png")
    du_response_body(ctx).should contain("SERVED DATA")
  end

  it "answers 404 for a tampered blob_key" do
    ctx = du_dispatch(
      du_build_context("GET", "/rails/active_storage/disk/bogus"),
      ActiveStorage::DiskController, "show",
      {"encoded_key" => "bogus"})
    ctx.response.status_code.should eq(404)
  end

  describe "full direct-upload flow (create → PUT → attach by signed_id)" do
    it "attaches the directly uploaded blob" do
      blob = ActiveStorage::Blob.create_before_direct_upload!(
        filename: "flow.png", byte_size: data.bytesize.to_i64,
        checksum: ActiveStorage::Checksum.md5_base64(data),
        content_type: "image/png")
      DU_BLOB_IDS << blob.id.not_nil!

      url = blob.service_url_for_direct_upload
      ctx = du_dispatch(
        du_build_context("PUT", url, data, "image/png"),
        ActiveStorage::DiskController, "update",
        {"encoded_token" => url.split("/").last})
      ctx.response.status_code.should eq(204)

      gallery = DuGallery.create
      DU_GALLERY_IDS << gallery.id.not_nil!
      gallery.photos.attach(blob.signed_id)
      gallery.photos.attached?.should be_true
      gallery.photos.blobs.first.download.should eq(data)
      gallery.photos.blobs.first.byte_size.should eq(data.bytesize.to_i64)
      gallery.photos.blobs.first.content_type.should eq("image/png")
    end
  end

  after_all do
    DU_BLOB_IDS.each do |id|
      if blob = ActiveStorage::Blob.find?(id)
        ActiveStorage::Attachment.where("blob_id = ?", id).to_a.each(&.destroy)
        DU_SERVICE.delete(blob.key.not_nil!) rescue nil
        blob.destroy
      end
    end
    DU_GALLERY_IDS.each do |id|
      ActiveRecord::Base.connection.exec("DELETE FROM galleries WHERE id = #{id}")
    end
  end
end
