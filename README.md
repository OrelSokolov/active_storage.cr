# active_storage.cr

A 1:1 Crystal port of **activestorage 8.1.4** (the Rails engine) under the
same `ActiveStorage` namespace: `has_one_attached`/`has_many_attached` on
ActiveRecord models, Disk and S3/MinIO services, image variants (via the
`vips` CLI), and Rails-compatible `signed_id` tokens
(`urlsafe_b64_nopad(...) + "--" + hmac_sha256-hex`, byte-for-byte against
the Rails 8.1 verifier). The S3 client is AWS SigV4 on OpenSSL +
`HTTP::Client` — no SDK. Suite: **95/95** specs replaying
27 + 19 + 16 + 37 oracle cases recorded from the real gem.

> ⚠️ EXPERIMENTAL FRAMEWORK, DO NOT USE IN PRODUCTION YET.

## Installation

```yaml
dependencies:
  active_storage_cr:
    github: OrelSokolov/active_storage.cr
```

```sh
shards install
```

Depends on `active_support.cr` and `active_record.cr`; the direct-upload
HTTP layer additionally needs `action_pack.cr` (opt-in require, not pulled
in by the umbrella `active_storage_cr`). Variants need the `vips` binary
in PATH.

## Usage

```crystal
require "active_storage_cr"

ActiveStorage.service = ActiveStorage::DiskService.new("/srv/storage")

class User < ActiveRecord::Base
  has_one_attached :avatar
  has_many_attached :photos
end

user.avatar.attach(File.read("/tmp/avatar.png"), "avatar.png", "image/png")
user.avatar.attached?      # => true
user.avatar.download       # => png bytes
user.avatar.variant(resize_to_limit: [100, 100], format: "webp").url

# has_many_attached: io triplets, existing blobs, or direct-upload signed ids
user.photos.attach(File.read("/tmp/1.jpg"), "1.jpg", "image/jpeg")
user.photos.attach([blob, other_blob])
user.photos.attach(blob.signed_id)

ActiveStorage::Blob.find_signed!(signed_id)  # raises on bad signature

# S3/MinIO (path-style, header signing, presigned GET/PUT):
ActiveStorage.service = ActiveStorage::S3Service.new(
  endpoint: "http://127.0.0.1:9000", bucket: "photos",
  access_key_id: "minioadmin", secret_access_key: "minioadmin")

# Direct upload controllers (opt-in; pulls action_pack):
require "active_storage_cr/controllers"
```

## Feature comparison vs activestorage 8.1.4

### DSL & attachables

| Feature | Original (activestorage) | Port (active_storage.cr) | Status |
|---|---|---|---|
| `has_one_attached` / `has_many_attached` macros | ✅ | Macros on `ActiveRecord::Base`; `avatar`, `avatar_blob`, `photos_attachments`, `photos_blobs` | ✅ |
| `attach` with io/filename/content_type | ✅ (IO objects) | Same, io is a `String` of bytes | ⚠️ partial |
| `attach` with `Blob` / `signed_id` / arrays | ✅ | `Attached::Many` only (`Blob`, `signed_id`, arrays, triplets); `Attached::One` io-form only | ⚠️ partial |
| `attach(ActionDispatch::Http::UploadedFile)` | ✅ | n/a in Crystal | ❌ |
| `attached?`, `detach`, `purge`, `download` | ✅ | Same (detach keeps blobs, purge removes them) | ✅ |
| `purge_later` | ✅ | Not ported | ❌ |
| `with_attached_*` scopes, `avatar=` setter | ✅ | Not ported | ❌ |
| Attachment order = insertion (`created_at, id`) | ✅ | Same | ✅ |

### Blobs, signed ids & services

| Feature | Original | Port | Status |
|---|---|---|---|
| Blob: `byte_size`, `content_type`, `checksum`, `key`, `image?`/`video?`/`audio?`/`text?` | ✅ | Same | ✅ |
| `Filename` sanitization (basename/extension) | ✅ | Same | ✅ |
| `signed_id` / `find_signed!` / `find_signed` (InvalidSignature vs RecordNotFound) | ✅ | Same wire format (both `data` and legacy message envelopes) | ✅ |
| Disk service | ✅ | `DiskService` | ✅ |
| S3 service (upload/download/delete, Content-MD5 integrity, presigned GET) | ✅ (aws-sdk-s3) | `S3Service` with SigV4 on OpenSSL, no SDK | ✅ |
| `config/storage.yml` registry, per-blob service (`service_name`) | ✅ | Single global `ActiveStorage.service` (name kept in tokens, not dispatched) | ❌ |
| `Mirror` service | ✅ | Not ported | ❌ |
| `custom_metadata`, `analyzed?`/AnalyzeJob | ✅ | Not ported | ❌ |

### Variants & representations

| Feature | Original | Port | Status |
|---|---|---|---|
| `variant(resize_to_limit:/resize_to_fill:/resize_and_pad:/crop:/rotate:/format:)` | ✅ (ruby-vips) | Same options, shell-out to `vips` CLI; png/jpg/webp/gif/tiff/bmp/avif | ✅ |
| `#url`, `#processed` (lazy + cache by variation key) | ✅ | Same; key shape `variants/{key}/[0-9a-f]{64}` matches | ✅ |
| Variation key derivation | HMAC-verifier + SHA256 | SHA256 of canonical JSON (same shape, different bytes) | ⚠️ partial |
| `preview` (ffmpeg/poppler), `representation` | ✅ | Not ported | ❌ |

### Direct upload & HTTP routes

| Feature | Original | Port | Status |
|---|---|---|---|
| `Blob.create_before_direct_upload!`, `service_url_for_direct_upload`, `service_headers_for_direct_upload` | ✅ | Same | ✅ |
| S3 presigned PUT (query-SigV4, UNSIGNED-PAYLOAD) | ✅ | Same format as aws-sdk (oracle-verified) | ✅ |
| `DirectUploadsController` (JSON 1:1) + `DiskController` (204/404/422, inline send_file) | ✅ | `src/controllers.cr`, opt-in require; routes via `CRails::Routes::Drawer#active_storage` | ✅ |
| `/rails/active_storage/blobs/{redirect,proxy}`, representations routes | ✅ | Not ported | ❌ |

## Deviations & Crystal-specific notes

- Single global `ActiveStorage.service` instead of the gem's per-blob
  service registry (`storage.yml` + `config.active_storage.service` are
  not implemented).
- Disk URLs are relative; the base comes from
  `ActiveStorage.disk_url_base` (Rails builds absolute URLs from
  `ActiveStorage::Current.url_options`).
- The verifier secret is `CRAILS_SECRET_KEY_BASE` with a fixed
  development fallback (Rails uses `secret_key_base`).
- Variation key is SHA256 of canonical JSON, not Rails' signed
  HMAC+SHA256 (Rails-internal); key shape is identical.
- Direct-upload controllers are an opt-in `require` so the shard doesn't
  pull action_pack transitively; namespace-compatible dispatch
  (`"active_storage/disk"`) works.
- The AR port writes `created_at`/`updated_at` unconditionally, so the
  blobs/attachments tables carry `updated_at` (Rails' tables don't).
- Attachables are typed as unions/overloads (String io, `Blob`,
  `signed_id`); `io:` is a `String` of bytes, not an IO object.

Full list with rationale: `PLAN.md` (Russian).

## Testing

```sh
crystal spec   # 95/95 — needs local PostgreSQL (db crails_as_test)
```

The S3 group additionally needs MinIO on `127.0.0.1:9000` (buckets
`as-oracle`, `as-crystal`); without it those specs skip with a notice.
Oracle cases recorded from activestorage 8.1.4: 27 core
(`oracle/cases.rb`), 19 has_many_attached (`cases_many.rb`), 16
signed_id (`cases_signed_id.rb`), 37 S3/direct-upload against live MinIO
(`cases_s3.rb`) — replayed 1:1 in `spec/`.

## Related

- CRails siblings: `active_record.cr`, `active_support.cr`,
  `action_pack.cr` — this shard is the ActiveStorage piece of the stack.
