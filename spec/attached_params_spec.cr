# Attachment params routing: uploaded files (and the nil of an unselected
# file field) reach the attachment through assign_attributes(Parameters) —
# Rails' record.update!(params) → avatar=<UploadedFile>, avatar=nil no-op
# (activestorage's has_one_attached setter, attached/model.rb).

require "spec"
# NB: active_storage_cr must be required before action_pack_cr — the
# reverse order overflows the compiler stack (docs/segfault-investigation).
require "../src/active_storage_cr"
require "action_pack_cr"
require "active_record_cr/parameters"

AP_TEST_URL = ENV["AS_TEST_URL"]? ||
              "postgres://root@/crails_as_test?host=/var/run/postgresql"

ActiveRecord::Base.establish_connection(AP_TEST_URL)
ActiveRecord::Base.connection.exec("DELETE FROM active_storage_attachments")
ActiveRecord::Base.connection.exec("DELETE FROM active_storage_blobs")
ActiveRecord::Base.connection.exec("DELETE FROM users")

class ParamsUser < ActiveRecord::Base
  set_table_name "users"
  has_one_attached :avatar
end

AP_ROOT = File.join(Dir.tempdir, "as_params_spec_#{Random::Secure.hex(8)}")
ActiveStorage.service = ActiveStorage::DiskService.new(AP_ROOT, "Local")

def uploaded_avatar : ActionController::UploadedFile
  ActionController::UploadedFile.new("me.png", "image/png", "AVATAR BYTES")
end

describe "attachment params routing" do
  it "attaches an uploaded file through update!(params)" do
    user = ParamsUser.create
    params = ActionController::Parameters.from({"avatar" => uploaded_avatar})
      .permit(:avatar)
    user.update!(params)

    user.avatar.attached?.should be_true
    user.avatar.filename.should eq("me.png")
    user.avatar.download.should eq("AVATAR BYTES")
    user.avatar_blob.not_nil!.content_type.should eq("image/png")
  end

  it "attaches through the avatar= setter directly" do
    user = ParamsUser.create
    user.avatar = uploaded_avatar
    user.avatar.attached?.should be_true
    user.avatar.filename.should eq("me.png")
  end

  it "treats nil (unselected file field) as a no-op" do
    user = ParamsUser.create
    user.avatar = uploaded_avatar
    params = ActionController::Parameters.from({"avatar" => nil}).permit(:avatar)
    user.update!(params)
    user.avatar.attached?.should be_true
    user.avatar.download.should eq("AVATAR BYTES")
  end

  it "raises for an uploaded file on a non-attachment attribute" do
    user = ParamsUser.create
    params = ActionController::Parameters.from({"email" => uploaded_avatar})
      .permit(:email)
    expect_raises(ArgumentError) do
      user.update!(params)
    end
  end
end
