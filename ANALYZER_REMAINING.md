# ANALYZER_REMAINING — ВЫПОЛНЕНО (2026-10-20, v0.1.3)

Порт ActiveStorage::Analyzer закрыт полностью. Итоги по пунктам:

## 1. Цель и формат metadata — ✅

`blob.analyze` пишет metadata в формате Rails:
`{"width":300,"height":180,"analyzed":true}` — порядок ключей как у
Ruby `metadata.merge(analyzed: true)`; анализатор вернул `{}` →
`{"analyzed":true}`; `analyzed?` → `metadata["analyzed"] == true`.
Отклонение: гем 8.1.4 хранит в metadata ещё `"identified":true`
(store-аксессор) — порт его не пишет (см. README, Deviations);
оракул-спеки сравнивают с вырезанным `identified`.

## 2. Файлы гема — ✅

- `analyzer.rb` (база, accept?/analyze_later?/metadata), `null_analyzer.rb`.
- `image_analyzer.rb` (+ EXIF 90°/270° → swap w/h) c подклассами
  `Vips` (`::Vips::Image.new_from_file`, sequential) и `ImageMagick`
  (MiniMagick dimensions + shell-out `identify -format %[orientation]`
  — у image_processing.cr нет orientation-ридера).
- `video_analyzer.rb`, `audio_analyzer.rb` — ffprobe JSON
  (-show_streams -show_format), rotation 90/270 swap, computed_height,
  display_aspect_ratio, tags.
- Диспетчеризация 1:1 Analyzable: `ActiveStorage.analyzers`
  (движковый список по умолчанию) + `accept?`, фолбэк NullAnalyzer.

## 3. Blob API + джоба — ✅

`analyze` (update) / `analyze!` (update!) / `analyzed?` /
`analyze_later` (inline без бэкенда; `ActiveStorage.analyze_job`
-wiring). `src/analyze_job.cr` — opt-in (active_job_cr), джоба несёт
id блоба, не GlobalID.

## 4. DiskService#path_for — ✅

Фан-аут `root/<key[0,2]>/<key[2,2]>/<key>` в шарде; подкласс
`CampfireDiskService` в приложении удалён.

## 5. Спеки/оракул — ✅

`oracle/cases_analyzer.rb` → `oracle/expected_analyzer.yml`
(21 кейс с гема 8.1.4): png/jpeg/gif/webp/tiff/avif, rotated
(EXIF 6), truncated, txt, video (640x480 + rot90 через Display
Matrix), audio mp3, analyzed? до/после, идемпотентность,
analyze_later inline. Зеркало `spec/analyzer_spec.cr` —
байт-в-байт. Фикстуры в oracle/fixtures (vips/convert/ffmpeg).

## 6. Приёмка в приложении — ✅

`MessageCreator.store_attachment` → `blob.analyze!` (синхронно в
production-транзакции); `app/models/image_dimensions.cr` удалён;
`tmp/smoke_storage_shard.cr` зелёный (metadata 3840x2160 → обёртка
width: 600.0px). HTTP-смоук: POST сообщения с PNG → metadata
`{"width":300,"height":180,"analyzed":true}`, файл в
storage/<k0,2>/<k2,2>/<key>, рендер width:150px/ratio 1.667.

## 7. Теги — v0.1.3 (заместо устаревшего v0.1.1 из плана: 0.1.2
уже был опубликован ранее)

Приложение резолвится `~> 0.1.1` → 0.1.3 без правок shard.yml.
Теги marcel v2.1.0 / image_processing v1.14.0 остаются открытыми
(shard.override.yml).
