# Port of ActiveStorage::Preview + Previewer (activestorage 8.2.alpha):
# app/models/active_storage/preview.rb, lib/active_storage/previewer.rb,
# lib/active_storage/previewer/video_previewer.rb.
#
# Deviations from the gem (documented):
#   * The gem attaches a real preview-image blob to the source blob
#     (has_one_attached :preview_image on Blob) and derives the poster
#     variant from THAT blob's key; the port stores the drawn frame on
#     the service under a deterministic key "previews/{blob.key}" and
#     the derived variant under "variants/{blob.key}/{variation.key}" —
#     the same key the on-demand representations path uses, so eager and
#     lazy processing share one cache entry.
#   * Previewer#draw captures the command's binary stdout in memory (the
#     gem streams into a Tempfile opened in tmpdir).
#   * Only VideoPreviewer is ported (the Poppler/MuPDF PDF previewers are
#     not); ActiveStorage.previewers defaults to [Previewer::VideoPreviewer].
#   * ActiveStorage::Notifications instrumentation is not ported.

module ActiveStorage
  class PreviewError < Exception; end
  class UnpreviewableError < Exception; end

  # Port of previewer/video_previewer.rb — draws the first frame with
  # ffmpeg (engine defaults: input "", output "-y -vframes 1 -f image2",
  # written to stdout as jpeg).
  module Previewer
    # What a previewer yields to Preview#process (the gem's attachable
    # io/filename/content_type triple).
    record Attachable, io : String, filename : String, content_type : String

    abstract class Base
      getter blob : Blob

      # Implement in a concrete subclass: true when the previewer can
      # generate an image from this blob.
      def self.accept?(blob : Blob) : Bool
        false
      end

      def initialize(@blob : Blob)
      end

      # Override in a concrete subclass: yields the preview image.
      def preview : Attachable
        raise NotImplementedError.new("subclass responsibility")
      end

      # --- previewer.rb private helpers --------------------------------

      # blob.open(tmpdir:) — the port stages the bytes in a temp file and
      # yields its PATH.
      private def download_blob_to_tempfile(&block : String -> U) : U forall U
        path = File.join(Dir.tempdir, "as_previewer_#{Random::Secure.hex(8)}")
        File.write(path, @blob.download)
        begin
          yield path
        ensure
          File.delete(path) rescue nil
        end
      end

      # Executes a system command and returns its binary stdout (the gem
      # captures the output into a tempfile via IO.popen). Raises
      # PreviewError when the command fails.
      private def draw(argv : Array(String)) : String
        stdout = IO::Memory.new
        stderr = IO::Memory.new
        status = Process.run(argv.first, argv[1..], output: stdout, error: stderr)
        unless status.success?
          raise PreviewError.new(
            "#{argv.first} failed (status #{status.exit_code}): #{stderr.to_s.chomp}")
        end
        stdout.to_s
      end
    end

    class VideoPreviewer < Base
      @@ffmpeg_exists : Bool? = nil

      def self.accept?(blob : Blob) : Bool
        blob.video? && ffmpeg_exists?
      end

      def self.ffmpeg_exists? : Bool
        @@ffmpeg_exists ||= begin
          Process.run(ffmpeg_path, {"-version"},
            output: Process::Redirect::Close, error: Process::Redirect::Close).success?
        rescue File::NotFoundError
          false
        end
      end

      def self.ffmpeg_path : String
        ActiveStorage.paths["ffmpeg"]? || "ffmpeg"
      end

      def preview : Attachable
        download_blob_to_tempfile do |input|
          # draw …, "-i", file.path, *video_preview_arguments, "-" — the
          # frame is written to stdout (the gem's trailing "-" output).
          argv = [self.class.ffmpeg_path] +
            ActiveStorage.video_preview_input_arguments.split + ["-i", input] +
            ActiveStorage.video_preview_arguments.split + ["-"]
          io = draw(argv)
          Attachable.new(io: io,
            filename: "#{Filename.new(@blob.filename.to_s).base}.jpg",
            content_type: "image/jpeg")
        end
      end
    end
  end

  # Port of app/models/active_storage/preview.rb.
  class Preview
    getter blob : Blob
    getter variation : Variation

    def initialize(@blob : Blob, @variation : Variation)
    end

    # Service key of the drawn preview frame (the port's stand-in for the
    # gem's attached preview-image blob).
    def frame_key : String
      "previews/#{@blob.key}"
    end

    # The gem: presentation.key — the derived variant of the preview
    # image, or the raw frame when the variation is empty
    # (variant? → presentation = image).
    def key : String
      variation.transformations.empty? ? frame_key : "variants/#{@blob.key}/#{variation.key}"
    end

    # Processes the preview if it has not been processed yet (the gem
    # generates the preview image once and attaches it to the blob).
    def processed : self
      process unless processed?
      self
    end

    # The gem: image.attached? — in the port, the derived file exists on
    # the service.
    def processed? : Bool
      ActiveStorage.service.exist?(key)
    end

    def content_type : String
      variation.transformations.empty? ? "image/jpeg" : variation.content_type
    end

    private def process : Nil
      frame = frame_bytes
      if variation.transformations.empty?
        ActiveStorage.service.upload(key, frame, content_type: content_type)
      else
        ActiveStorage.service.upload(key, variation.transform(frame, "jpg"),
          content_type: content_type)
      end
    end

    # Draws the frame once and caches it on the service; later calls
    # (including other variations of the same blob) reuse it.
    private def frame_bytes : String
      unless ActiveStorage.service.exist?(frame_key)
        attachable = previewer_class.new(@blob).preview
        ActiveStorage.service.upload(frame_key, attachable.io,
          content_type: attachable.content_type)
      end
      ActiveStorage.service.download(frame_key)
    end

    private def previewer_class : Previewer::Base.class
      ActiveStorage.previewers.find { |klass| klass.accept?(@blob) } ||
        raise(UnpreviewableError.new(
          "No previewer found for blob with ID=#{@blob.id} and content_type=#{@blob.content_type}"))
    end
  end

  # The engine's defaults (engine.rb): config.active_storage.paths (empty;
  # apps may set paths[:ffmpeg]), video preview arguments, and the
  # previewers list — the PDF previewers are not ported.
  @@paths = {} of String => String
  @@video_preview_input_arguments = ""
  @@video_preview_arguments = "-y -vframes 1 -f image2"
  @@previewers = [Previewer::VideoPreviewer] of Previewer::Base.class

  def self.paths : Hash(String, String)
    @@paths
  end

  def self.video_preview_input_arguments : String
    @@video_preview_input_arguments
  end

  def self.video_preview_input_arguments=(args : String) : Nil
    @@video_preview_input_arguments = args
  end

  def self.video_preview_arguments : String
    @@video_preview_arguments
  end

  def self.video_preview_arguments=(args : String) : Nil
    @@video_preview_arguments = args
  end

  def self.previewers : Array(Previewer::Base.class)
    @@previewers
  end

  def self.previewers=(previewers : Array(Previewer::Base.class)) : Nil
    @@previewers = previewers
  end
end
