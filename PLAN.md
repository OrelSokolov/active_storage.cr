# active_storage.cr — порт ActiveStorage

> ⚠️ EXPERIMENTAL FRAMEWORK, DO NOT USE IN PRODUCTION YET.

Неймспейс: `ActiveStorage` — 1:1. Оценка: ~85% (DSL — макрос 1:1;
стоимость — обработка картинок vips/ffmpeg, не разрыв API).

## API 1:1

### DSL
- `has_one_attached :avatar (dependent: :purge_later, service:,
  strict_loading:, analyze:)` — макрос; генерит `avatar`, `avatar=`,
  `avatar_attachment`, `avatar_blob`, scope `with_attached_avatar`
- `has_many_attached :photos` (+ блок именованных вариантов:
  `attachable.variant :thumb, resize_to_limit: [100, 100]`)

### Attachable-прокси
- `avatar.attach(io:, filename:, content_type:)` / `attach(signed_id)`
  / `attach(Blob)` / `attach(UploadedFile)` (union-типизация)
- `avatar.attached?`, `detach`, `purge`, `purge_later`
- `avatar.variant(resize_to_limit:/resize_to_fill:/resize_and_pad:/
  crop:/rotate:/format:)` → `#url`, `#processed`, `#download`
- `avatar.preview(...)`, `representation(...)`
- `avatar.url (expires_in:, disposition:, filename:)` — direct URLs
- `avatar.download { |chunk| }`, `open { |tmpfile| }`
- Blob: `byte_size, content_type, filename (basename/extension/
  sanitized), checksum, metadata, key, signed_id, image?/video?/
  audio?, custom_metadata, analyzed?`
- `ActiveStorage::Blob.find_signed!`

### Сервисы и конфиг
- `config/storage.yml`: `Disk (root:)`, `S3`, `Mirror`; выбор средой:
  `config.active_storage.service = :local`
- Маршруты `/rails/active_storage/blobs/{redirect,proxy}/...`,
  `/rails/active_storage/representations/...`,
  `POST /rails/active_storage/direct_uploads` (presigned PUT для S3)
- Фоновые джобы: AnalyzeJob, PurgeJob (active_job.cr)

## Реализация

- Variants: libvips-биндинг (кандидат) или шелл-аут `vips`; превью
  PDF/видео — ffmpeg/poppler шелл-аут (как у Rails); ленивая обработка
  + кеш по variation key.
- S3-сервис: presigned URL через sigv4 (OpenSSL stdlib) — без SDK.
- `ActiveStorage::Current.url_options` — fiber-local.
- Утиная типизация attachable (7 форм в Rails) → перегрузки/union.

## Статус (Iteration 7 — has_many_attached + signed_id + direct upload)

- Oracle many: `oracle/cases_many.rb` → `oracle/expected_many.yml`, 19
  кейсов сняты с activestorage 8.1.4 (attach поштучно/массивом/Blob,
  порядок attachments = вставке (created_at,id), detach сохраняет блобы,
  purge, re-attach). Зеркало: `spec/many_spec.cr` (порядковые кейсы —
  одним sequence-примером; счётные кейсы считаются по строкам этого
  флоу — общая PG-БД с соседними spec-файлами).
- Oracle signed_id: `oracle/cases_signed_id.rb` →
  `oracle/expected_signed_id.yml`, 16 кейсов (verifier как в Rails 8.1
  приложении: SHA256, url_safe, json_allow_marshal, фиксированный
  секрет): wire-формат signed_id
  `urlsafe_b64_nopad({"_rails":{"data":<id>,"pur":"blob_id"}}) + "--" +
  hmac_sha256-hex`, find_signed!/find_signed (InvalidSignature vs
  RecordNotFound), disk-токены (purpose blob_token/blob_key, exp
  iso8601(3)). Чтение понимает оба конверта (data / legacy message),
  как Rails. Зеркало: `spec/signed_id_spec.cr` — байты байт-в-байт.
- Direct upload (P1 закрыт): `Blob.create_before_direct_upload!`,
  `#signed_id`/`find_signed!`, `service_url_for_direct_upload`/
  `service_headers_for_direct_upload`; Disk — verifier-токен
  (blob_token) в URL `/rails/active_storage/disk/<token>`; S3 —
  presigned PUT query-SigV4 (SignedHeaders
  `content-length;content-md5;content-type;host`, UNSIGNED-PAYLOAD —
  фактический aws-sdk-формат снят оракулом `s3du_*`, expected_s3.yml
  31→37 кейсов: PUT 200, roundtrip, битый checksum 403, headers с
  Content-Disposition). HTTP-слой: `src/controllers.cr` (opt-in
  require — НЕ в зонтичном src, тянет action_pack): DirectUploadsController
  (JSON 1:1 direct_upload_json: id/byte_size — числами) + DiskController
  (update: token+Content-Type/Length/MD5-проверка → 204/404/422;
  show: blob_key-URL → send_file inline), маршруты через
  `CRails::Routes::Drawer#active_storage` внутри draw-блока приложения.
  shard.yml: path-зависимость action_pack_cr.
- MessageVerifier (active_support.cr): формат с метаданными (purpose/
  expires) — Rails-8.1 wire (urlsafe-b64 без padding + hmac-hex),
  turbo-формат без метаданных не изменился (оракул turbo зелёный).
- Отклонения от Rails (задокументированы): единственный глобальный
  сервис вместо реестра Blob.services (service_name в токенах возится,
  но не диспетчеризуется); Disk-URL относительные, база —
  `ActiveStorage.disk_url_base` (Rails строит абсолютные из
  ActiveStorage::Current.url_options); секрета —
  CRAILS_SECRET_KEY_BASE с dev-фолбеком; AR-порт не принимает явный
  pk в create — сиды пиннят id SQL-апдейтом; direct-upload контроллеры
  — opt-in require (неймспейс-совместимость dispatch
  "active_storage/disk" работает).
- Спеки шарда: 95/95 (`crystal spec`; нужны postgres crails_as_test и
  MinIO для s3-части — без MinIO s3-группа скипается с notice).
  Соседи: action_text 48/48, action_mailbox 29/29 на новых
  active_support/active_storage.

## Статус (Iteration 6 — S3/MinIO + variants)

- Oracle: `oracle/cases.rb` → `oracle/expected.yml`, 27 кейсов сняты с
  activestorage 8.1.4 (SQLite in-memory, Disk-сервис; blob create/find/
  checksum/content-type-предикаты/filename sanitize, attach/detach/purge,
  has_one_attached). Зеркало: `spec/oracle_spec.cr` — 29/29 (27 оракул +
  mirrors-check + юнит purge).
- Oracle S3+variants: `oracle/cases_s3.rb` → `oracle/expected_s3.yml`,
  31 кейс снят с оригинального гема (aws-sdk-s3 + image_processing/
  ruby-vips) против живого MinIO: upload/download/exist?/delete,
  Content-MD5 integrity (IntegrityError), FileNotFoundError,
  presigned GET (X-Amz-Signature, fetch 200, expiry 403),
  blob на S3, variants (ключ `variants/{key}/{64hex}`, processed,
  размеры 100x60/64x64/180x300, rotate, webp content-type),
  has_one_attached поверх S3. Зеркало: `spec/s3_spec.cr` — 32/32
  (31 оракул + mirrors-check); сам скипается с notice, если MinIO
  недоступен (см. `oracle/cases_s3.rb` и `tmp/minio-img/`).
- Реализовано (P0): `filename.cr`, `service.cr` (абстрактный `Service`
  + `DiskService`), `blob.cr`, `attached.cr` (макрос
  `has_one_attached` через reopen `ActiveRecord::Base`).
- Реализовано (P1, эта итерация): `s3_service.cr` — S3Service c AWS
  SigV4 на OpenSSL + `HTTP::Client` (без SDK; path-style, header-
  signing, Content-MD5, presigned GET c response-content-disposition/
  type); `variation.cr` + `variant.cr` — variants через шелл-аут
  `vips` CLI (`thumbnail --size=down/--crop=attention`, `rot d90`,
  `crop`, `embed`; форматы png/jpg/webp/gif/tiff/bmp/avif);
  `Blob#variant(**)`/`#url`, `Attached::One#variant/#url`,
  `Blob#variable?/representable?`.
- Отклонения от Rails (сознательные, P2+): variation key — у Rails
  HMAC-verifier + SHA256 (Rails-internal), у порта SHA256 от
  canonical JSON (форма `variants/{key}/[0-9a-f]{64}` совпадает);
  сервис-реестр — глобальный `ActiveStorage.service` (storage.yml-
  конфиг и `:local`/`:minio` переключение средой — P2); preview
  (ffmpeg/poppler), direct upload (presigned PUT), Mirror, purge_later
  — P2. Фикстурные таблицы blobs/attachments несут `updated_at`
  (AR-порт пишет оба timestamp при insert безусловно; у Rails
  storage-таблиц их нет).
- Спеки шарда запускаются `crystal spec` из корня шарда — кодеген AR
  подхватывает `db/schema.yml`; нужен postgres (`crails_as_test`) и
  MinIO для S3-части.

### MinIO для тестов (docker)

MinIO убрал образы с Docker Hub/quay (анонимно), поэтому образ
собирается из официального бинарника GitHub releases (sha256
проверяется вручную): `tmp/minio-img/` (Dockerfile + минимальные
инструкции). Запуск:

```
docker build -t as-minio:RELEASE.2025-09-07 tmp/minio-img
docker run -d --name as-minio -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
  as-minio:RELEASE.2025-09-07
# бакеты (однократно):
ruby -raws-sdk-s3 -e 'c=Aws::S3::Client.new(access_key_id:"minioadmin",secret_access_key:"minioadmin",region:"us-east-1",endpoint:"http://127.0.0.1:9000",force_path_style:true); %w[as-oracle as-crystal].each{|b| begin; c.create_bucket(bucket:b); rescue; end}'
ruby oracle/cases_s3.rb > oracle/expected_s3.yml   # переснятие оракула
crystal spec                                        # 61 примеров
```


## Фазы

- P0: Disk-сервис, has_one_attached/has_many_attached, attach/attached?/
  download/url, blobs/attachments-таблицы, AnalyzeJob. — ✅ (Iteration 5)
- P1: S3-сервис (sigv4 без SDK), variants (vips), presigned url. — ✅
  (Iteration 6, oracle: expected_s3.yml)
- P1.x: has_many_attached + signed_id + direct upload (presigned PUT,
  DirectUploads/Disk-контроллеры). — ✅ (Iteration 7, oracle:
  expected_many.yml / expected_signed_id.yml / expected_s3.yml s3du_*)
- P1.x: preview (ffmpeg/poppler), purge_later, Mirror, storage.yml-реестр.
- P2: именованные варианты-блоки, custom_metadata полный, proxy-режим.

## Готово, когда

`user.avatar.attach(io:, filename:)` + `user.avatar.variant(resize_to_limit:
[100,100]).url` отдают работающий URL ресайзнутой картинки — и с диска,
и из S3/MinIO (presigned). — ✅

## Зависимости

active_record.cr, active_job.cr, libvips (P1), ffmpeg/poppler (P1).
