# Port of ActiveStorage::Service::S3Service — S3/MinIO backend with
# AWS Signature V4 implemented over OpenSSL + HTTP::Client (no SDK).
# Path-style addressing ("http://host:port/bucket/key"), which is what
# MinIO (and AWS with force_path_style) expects.
#
# Oracle: oracle/cases_s3.rb (activestorage 8.1.4 against live MinIO):
# upload/download/exist?/delete, Content-MD5 integrity, presigned GET
# (X-Amz-Signature), variants over S3.

require "openssl"
require "http/client"
require "uri"

module ActiveStorage
  class S3Service < Service
    class Error < Exception
    end

    def initialize(endpoint : String, bucket : String,
                   access_key_id : String, secret_access_key : String,
                   region : String = "us-east-1", name : String = "S3")
      super(name)
      @endpoint = URI.parse(endpoint)
      @bucket = bucket
      @access_key_id = access_key_id
      @secret_access_key = secret_access_key
      @region = region
    end

    def upload(key : String, data : String | Bytes, checksum : String? = nil,
               content_type : String? = nil) : Nil
      body = data.is_a?(String) ? data.to_slice : data
      ctx = SigV4.new(@access_key_id, @secret_access_key, @region, Time.utc)
      headers = HTTP::Headers{
        "Host"                 => host_header,
        "x-amz-date"           => ctx.amz_date,
        "x-amz-content-sha256" => ctx.sha256_hex(body),
      }
      headers["Content-Type"] = content_type if content_type
      headers["Content-MD5"] = checksum if checksum
      headers["Content-Length"] = body.size.to_s
      ctx.sign_headers!("PUT", object_path(key), headers)

      response = exec("PUT", object_path(key), headers, body)
      case response.status.code
      when .in?(200, 201, 204) then nil
      when 400
        if checksum
          raise IntegrityError.new("checksum mismatch for #{key}")
        end
        raise Error.new("S3 PUT #{key}: #{response.status} #{error_snippet(response)}")
      else
        raise Error.new("S3 PUT #{key}: #{response.status} #{error_snippet(response)}")
      end
    end

    def download(key : String) : String
      ctx = SigV4.new(@access_key_id, @secret_access_key, @region, Time.utc)
      headers = HTTP::Headers{
        "Host"                 => host_header,
        "x-amz-date"           => ctx.amz_date,
        "x-amz-content-sha256" => ctx.sha256_hex(""),
      }
      ctx.sign_headers!("GET", object_path(key), headers)

      response = exec("GET", object_path(key), headers)
      case response.status.code
      when 200
        response.body
      when 404, 403 # MinIO: 404 NoSuchKey; 403 for a few edge states
        raise FileNotFoundError.new("missing object #{key}")
      else
        raise Error.new("S3 GET #{key}: #{response.status} #{error_snippet(response)}")
      end
    end

    def exist?(key : String) : Bool
      ctx = SigV4.new(@access_key_id, @secret_access_key, @region, Time.utc)
      headers = HTTP::Headers{
        "Host"                 => host_header,
        "x-amz-date"           => ctx.amz_date,
        "x-amz-content-sha256" => ctx.sha256_hex(""),
      }
      ctx.sign_headers!("HEAD", object_path(key), headers)

      case (response = exec("HEAD", object_path(key), headers)).status.code
      when .in?(200, 204) then true
      when 404            then false
      else                     raise Error.new("S3 HEAD #{key}: #{response.status}")
      end
    end

    def delete(key : String) : Nil
      ctx = SigV4.new(@access_key_id, @secret_access_key, @region, Time.utc)
      headers = HTTP::Headers{
        "Host"                 => host_header,
        "x-amz-date"           => ctx.amz_date,
        "x-amz-content-sha256" => ctx.sha256_hex(""),
      }
      ctx.sign_headers!("DELETE", object_path(key), headers)

      response = exec("DELETE", object_path(key), headers)
      return if response.status.code.in?(200, 202, 204, 404)
      raise Error.new("S3 DELETE #{key}: #{response.status} #{error_snippet(response)}")
    end

    # Presigned GET URL (the gem's S3Service#url for private buckets).
    def url(key : String, expires_in : Int32 = 300,
            disposition : String? = nil, filename : String? = nil,
            content_type : String? = nil) : String
      ctx = SigV4.new(@access_key_id, @secret_access_key, @region, Time.utc)
      params = {
        "X-Amz-Algorithm"     => "AWS4-HMAC-SHA256",
        "X-Amz-Credential"    => ctx.credential,
        "X-Amz-Date"          => ctx.amz_date,
        "X-Amz-Expires"       => expires_in.to_s,
        "X-Amz-SignedHeaders" => "host",
      }
      if disposition && filename
        params = params.merge({
          "response-content-disposition" =>
            %(#{disposition}; filename="#{ActiveStorage::Filename.new(filename).sanitized}"),
        })
      end
      params = params.merge({"response-content-type" => content_type}) if content_type
      query = SigV4.canonical_query(params)
      canonical_request = String.build do |io|
        io << "GET\n" << object_path(key) << '\n' << query << '\n'
        io << "host:" << host_header << "\n\nhost\nUNSIGNED-PAYLOAD"
      end
      "#{endpoint_root}#{object_path(key)}?#{query}&X-Amz-Signature=#{ctx.sign(canonical_request)}"
    end

    # Presigned PUT URL for direct uploads — the aws-sdk shape the gem
    # produces (`object.presigned_url(:put, content_type:, content_md5:,
    # whitelist_headers: ["content-length"])`, oracle s3du_url_shape):
    # query-SigV4, UNSIGNED-PAYLOAD, SignedHeaders
    # "content-length;content-md5;content-type;host" (the client must
    # send Content-Length/Content-MD5/Content-Type with the body).
    def url_for_direct_upload(key : String, expires_in : Int32,
                              content_type : String?, content_length : Int64,
                              checksum : String?) : String
      ctx = SigV4.new(@access_key_id, @secret_access_key, @region, Time.utc)
      params = {
        "X-Amz-Algorithm"     => "AWS4-HMAC-SHA256",
        "X-Amz-Credential"    => ctx.credential,
        "X-Amz-Date"          => ctx.amz_date,
        "X-Amz-Expires"       => expires_in.to_s,
        "X-Amz-SignedHeaders" => "content-length;content-md5;content-type;host",
      }
      query = SigV4.canonical_query(params)
      canonical_request = String.build do |io|
        io << "PUT\n" << object_path(key) << '\n' << query << '\n'
        io << "content-length:" << content_length << '\n'
        io << "content-md5:" << checksum.to_s << '\n'
        io << "content-type:" << content_type.to_s << '\n'
        io << "host:" << host_header << "\n\n"
        io << "content-length;content-md5;content-type;host\nUNSIGNED-PAYLOAD"
      end
      "#{endpoint_root}#{object_path(key)}?#{query}&X-Amz-Signature=#{ctx.sign(canonical_request)}"
    end

    # Headers the client sends with the presigned PUT (all four are the
    # signed ones from url_for_direct_upload plus the gem's
    # Content-Disposition, oracle s3du_headers).
    def headers_for_direct_upload(key : String, content_type : String?,
                                  content_length : Int64,
                                  checksum : String?,
                                  filename : String? = nil) : Hash(String, String)
      headers = {} of String => String
      headers["Content-Type"] = content_type.to_s
      headers["Content-MD5"] = checksum.to_s if checksum
      if filename
        headers["Content-Disposition"] =
          ActiveStorage.content_disposition_with(filename: filename)
      end
      headers
    end

    private def object_path(key : String) : String
      "/" + ([@bucket] + key.split('/').map { |s| SigV4.uri_encode(s) }).join("/")
    end

    private def exec(method : String, path : String, headers : HTTP::Headers,
                     body : Bytes? = nil) : HTTP::Client::Response
      request = HTTP::Request.new(method, path, headers,
        body ? IO::Memory.new(body) : nil)
      client = HTTP::Client.new(@endpoint.host.not_nil!, @endpoint.port.not_nil!,
        tls: @endpoint.scheme == "https")
      client.exec(request)
    end

    private def host_header : String
      port = @endpoint.port.not_nil!
      if (@endpoint.scheme == "https" && port == 443) ||
         (@endpoint.scheme == "http" && port == 80)
        @endpoint.host.not_nil!
      else
        "#{@endpoint.host}:#{port}"
      end
    end

    private def endpoint_root : String
      "#{@endpoint.scheme}://#{host_header}"
    end

    private def error_snippet(response : HTTP::Client::Response) : String
      body = response.body?
      body ? body[0, 200] : ""
    end

    # AWS Signature V4 — one instance signs one operation (headers or
    # presigned query) against a single timestamp.
    private struct SigV4
      attr_reader amz_date : String

      def initialize(@access_key_id : String, @secret_access_key : String,
                     @region : String, time : Time)
        @date_stamp = time.to_s("%Y%m%d")
        @amz_date = time.to_s("%Y%m%dT%H%M%SZ")
      end

      def credential : String
        "#{@access_key_id}/#{scope}"
      end

      # Credential scope WITHOUT the access key (what the string-to-sign
      # carries): date/region/service/aws4_request.
      def scope : String
        "#{@date_stamp}/#{@region}/s3/aws4_request"
      end

      def sha256_hex(data : String | Bytes) : String
        OpenSSL::Digest.new("SHA256").update(data).final.hexstring
      end

      def sign_headers!(method : String, path : String, headers : HTTP::Headers) : Nil
        payload_hash = headers["x-amz-content-sha256"]
        signed = [] of String
        headers.each { |k, _| signed << k.downcase }
        signed.sort!
        canonical_headers = signed.map { |h| "#{h}:#{headers[h].strip}" }.join("\n")
        canonical_request = String.build do |io|
          io << method.upcase << '\n' << path << "\n\n"
          io << canonical_headers << "\n\n"
          io << signed.join(";") << '\n' << payload_hash
        end
        headers["Authorization"] =
          "AWS4-HMAC-SHA256 Credential=#{credential}, " \
          "SignedHeaders=#{signed.join(";")}, Signature=#{sign(canonical_request)}"
      end

      def sign(canonical_request : String) : String
        string_to_sign = String.build do |io|
          io << "AWS4-HMAC-SHA256\n" << @amz_date << '\n' << scope << '\n'
          io << sha256_hex(canonical_request)
        end
        key = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, "AWS4" + @secret_access_key, @date_stamp)
        key = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, key, @region)
        key = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, key, "s3")
        key = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, key, "aws4_request")
        OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, key, string_to_sign).hexstring
      end

      def self.canonical_query(params : Hash(String, String)) : String
        params.keys.sort.map { |k| "#{uri_encode(k)}=#{uri_encode(params[k])}" }.join("&")
      end

      def self.uri_encode(s : String) : String
        String.build do |io|
          s.each_byte do |b|
            if (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) ||
               (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E
              io.write_byte(b)
            else
              io << "%" << b.to_s(16).upcase.rjust(2, '0')
            end
          end
        end
      end
    end
  end
end
