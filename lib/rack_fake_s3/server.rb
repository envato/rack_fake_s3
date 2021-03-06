require 'rack'
require 'rack/request'
require 'rack/response'
require 'rack/server'
require 'rack/lint'

require 'rack_fake_s3/file_store'
require 'rack_fake_s3/xml_adapter'
require 'rack_fake_s3/bucket_query'
require 'rack_fake_s3/errors'

module RackFakeS3
  require 'webrick'
  class Request
    CREATE_BUCKET = "CREATE_BUCKET"
    LIST_BUCKETS = "LIST_BUCKETS"
    LS_BUCKET = "LS_BUCKET"
    HEAD = "HEAD"
    STORE = "STORE"
    OPTIONS = "OPTIONS"
    COPY = "COPY"
    GET = "GET"
    GET_ACL = "GET_ACL"
    SET_ACL = "SET_ACL"
    MOVE = "MOVE"
    DELETE_OBJECT = "DELETE_OBJECT"
    DELETE_BUCKET = "DELETE_BUCKET"

    attr_accessor :bucket,:object,:type,:src_bucket,
                  :src_object,:method,:rack_request,
                  :path,:is_path_style,:query,:http_verb

    def inspect
      puts "-----Inspect RackFakeS3 Request"
      puts "Type: #{@type}"
      puts "Is Path Style: #{@is_path_style}"
      puts "Request Method: #{@method}"
      puts "Bucket: #{@bucket}"
      puts "Object: #{@object}"
      puts "Src Bucket: #{@src_bucket}"
      puts "Src Object: #{@src_object}"
      puts "Query: #{@query}"
      puts "-----Done"
    end
  end

  class Servlet
    def initialize(app,store,hostname)
      raise "store can't be nil" if store.nil?
      raise "hostname can't be nil" if hostname.nil?

      @app = app
      @store = store
      @hostname = hostname
      @root_hostnames = [hostname,'localhost','s3.amazonaws.com','s3.localhost']
    end

    def call(env)
      request = Rack::Request.new(env)
      s_req = normalize_request(request)

      if s_req
        dup.perform(env, s_req)
      elsif @app
        @app.call(env)
      else
        halt 404
      end
    end

    def perform(env, s_req)
      response = Rack::Response.new

      send(:"do_#{s_req.http_verb}", s_req, response)

      response.finish
    end

    def do_GET(s_req, response)
      request = s_req.rack_request

      case s_req.type
      when 'LIST_BUCKETS'
        response.status = 200
        response['Content-Type'] = 'application/xml'
        buckets = @store.buckets
        response.write XmlAdapter.buckets(buckets)
      when 'LS_BUCKET'
        bucket_obj = @store.get_bucket(s_req.bucket)
        if bucket_obj
          response.status = 200
          response['Content-Type'] = "application/xml"
          query = {
            :marker => s_req.query["marker"] ? s_req.query["marker"].to_s : nil,
            :prefix => s_req.query["prefix"] ? s_req.query["prefix"].to_s : nil,
            :max_keys => s_req.query["max-keys"] ? s_req.query["max-keys"].to_i : nil,
            :delimiter => s_req.query["delimiter"] ? s_req.query["delimiter"].to_s : nil
          }

          bq = bucket_obj.query_for_range(query)
          response.write XmlAdapter.bucket_query(bq)
        else
          response.status = 404
          response.write XmlAdapter.error_no_such_bucket(s_req.bucket)
          response['Content-Type'] = "application/xml"
        end
      when 'GET_ACL'
        response.status = 200
        response.write XmlAdapter.acl()
        response['Content-Type'] = 'application/xml'
      when 'GET'
        real_obj = @store.get_object(s_req.bucket,s_req.object,request)
        if !real_obj
          response.status = 404
          response.write ""
          return
        end

        response.status = 200
        response['Content-Type'] = real_obj.content_type
        content_length = File::Stat.new(real_obj.io.path).size
        response['Etag'] = real_obj.md5
        response['Accept-Ranges'] = "bytes"

        # Added Range Query support
        if range = request.env["HTTP_RANGE"]
          response.status = 206
          if range =~ /bytes=(\d*)-(\d*)/
            start = $1.to_i
            finish = $2.to_i
            finish_str = ""
            if finish == 0
              finish = content_length - 1
              finish_str = "#{finish}"
            else
              finish_str = finish.to_s
            end

            bytes_to_read = finish - start + 1
            response['Content-Range'] = "bytes #{start}-#{finish_str}/#{content_length}"
            real_obj.io.pos = start
            response.write real_obj.io.read(bytes_to_read)
            return
          end
        end
        response['Content-Length'] = File::Stat.new(real_obj.io.path).size.to_s
        if s_req.http_verb == 'HEAD'
          response.write ""
        else
          response.length = real_obj.io.size.to_s
          response.body = real_obj.io
        end
      end
    end
    alias :do_HEAD :do_GET

    def do_PUT(s_req,response)
      request = s_req.rack_request

      case s_req.type
      when Request::COPY
        @store.copy_object(s_req.src_bucket,s_req.src_object,s_req.bucket,s_req.object)
      when Request::STORE
        bucket_obj = @store.get_bucket(s_req.bucket)
        if !bucket_obj
          # Lazily create a bucket.  TODO fix this to return the proper error
          bucket_obj = @store.create_bucket(s_req.bucket)
        end

        real_obj = @store.store_object(bucket_obj,s_req.object,s_req.rack_request)

        response['Etag'] = real_obj.md5
      when Request::CREATE_BUCKET
        @store.create_bucket(s_req.bucket)
      end

      response.status = 200
      response.write ""
      response['Content-Type'] = "text/xml"
    end

    def do_POST(request,response)
       # check that we've received file data
       unless request.rack_request.content_type =~ /^multipart\/form-data; boundary=(.+)/
         raise 'bad request'
       end

       key=request.path
       success_action_redirect=request.rack_request.params['success_action_redirect']
       success_action_status=request.rack_request.params['success_action_status']

       filename = 'default'
       filename = $1 if request.rack_request.body =~ /filename="(.*)"/
       key=key.gsub('${filename}', filename)

       bucket_obj = @store.get_bucket(request.bucket) || @store.create_bucket(request.bucket)
       real_obj=@store.store_object(bucket_obj, key, request.rack_request)

       response['Etag'] = "\"#{real_obj.md5}\""
       response.body = []
       if success_action_redirect
         response.status = 307
         response['Location']=success_action_redirect
       else
         response.status = success_action_status || 204
         if response.status=="201"
           response.body << <<-eos.strip
             <?xml version="1.0" encoding="UTF-8"?>
             <PostResponse>
               <Location>#{request.rack_request.scheme}://#{request.rack_request.host_with_port}/#{key}</Location>
               <Bucket>#{request.bucket}</Bucket>
               <Key>#{key}</Key>
               <ETag>#{response['Etag']}</ETag>
             </PostResponse>
           eos
         end
       end
       response['Content-Type'] = 'text/xml'
       response['Access-Control-Allow-Origin']='*'
     end

    def do_DELETE(s_req,response)
      request = s_req.rack_request
      case s_req.type
      when Request::DELETE_OBJECT
        bucket_obj = @store.get_bucket(s_req.bucket)
        @store.delete_object(bucket_obj,s_req.object,s_req.rack_request)
      when Request::DELETE_BUCKET
        @store.delete_bucket(s_req.bucket)
      end

      response.status = 204
      response.write ""
    end

    def do_OPTIONS(request, response)
      response["Access-Control-Allow-Origin"]="*"
    end

    private

    def normalize_delete(rack_req,s_req)
      path = path_for_rack_request(rack_req)
      path_len = path.size
      query = rack_req.params
      if path == "/" and s_req.is_path_style
        # Probably do a 404 here
      else
        if s_req.is_path_style
          elems = path[1,path_len].split("/")
          s_req.bucket = elems[0]
        else
          elems = path.split("/")
        end

        if elems.size == 0
          raise UnsupportedOperation
        elsif elems.size == 1
          s_req.type = Request::DELETE_BUCKET
          s_req.query = query
        else
          s_req.type = Request::DELETE_OBJECT
          object = elems[1,elems.size].join('/')
          s_req.object = object
        end
      end
    end

    def normalize_get(rack_req,s_req)
      path = path_for_rack_request(rack_req)
      path_len = path.size
      query = rack_req.params
      if path == "/" and s_req.is_path_style
        s_req.type = Request::LIST_BUCKETS
      else
        if s_req.is_path_style
          elems = path[1,path_len].split("/")
          s_req.bucket = elems[0]
        else
          elems = path.split("/")
        end

        if elems.size == 0
          # List buckets
          s_req.type = Request::LIST_BUCKETS
        elsif elems.size == 1
          s_req.type = Request::LS_BUCKET
          s_req.query = query
        else
          if query.has_key?("acl")
            s_req.type = Request::GET_ACL
          else
            s_req.type = Request::GET
          end
          object = elems[1,elems.size].join('/')
          s_req.object = object
        end
      end
    end

    def normalize_put(rack_req,s_req)
      path = path_for_rack_request(rack_req)
      path_len = path.size
      if path == "/"
        if s_req.bucket
          s_req.type = Request::CREATE_BUCKET
        end
      else
        if s_req.is_path_style
          elems = path[1,path_len].split("/")
          s_req.bucket = elems[0]
          if elems.size == 1
            s_req.type = Request::CREATE_BUCKET
          else
            if rack_req.fullpath =~ /\?acl/
              s_req.type = Request::SET_ACL
            else
              s_req.type = Request::STORE
            end
            s_req.object = elems[1,elems.size].join('/')
          end
        else
          if rack_req.fullpath =~ /\?acl/
            s_req.type = Request::SET_ACL
          else
            s_req.type = Request::STORE
          end
          s_req.object = rack_req.path
        end
      end

      copy_source = rack_req.env["HTTP_X_AMZ_COPY_SOURCE"]
      if copy_source
        src_elems = copy_source.split("/")
        root_offset = src_elems[0] == "" ? 1 : 0
        s_req.src_bucket = src_elems[root_offset]
        s_req.src_object = src_elems[1 + root_offset,src_elems.size].join("/")
        s_req.type = Request::COPY
      end
    end

    def normalize_post(rack_req,s_req)
      path = path_for_rack_request(rack_req)
      path_len = path.size
      s_req.path = rack_req.params['key']
      s_req.type = Request::STORE

      s_req.rack_request = rack_req
    end

    def nomalize_options(rack_req, s_req)
      s_req.type = Request::OPTIONS
    end

    # This method takes a rack request and generates a normalized RackFakeS3 request
    def normalize_request(rack_req)
      host = rack_req.host

      s_req = Request.new
      s_req.path = path_for_rack_request(rack_req)
      s_req.is_path_style = true
      s_req.rack_request = rack_req

      if !@root_hostnames.include?(host)
        s_req.bucket = host.split(".")[0]
        s_req.is_path_style = false
      end

      s_req.http_verb = rack_req.request_method

      case rack_req.request_method
      when 'PUT'
        normalize_put(rack_req,s_req)
      when 'GET','HEAD'
        normalize_get(rack_req,s_req)
      when 'DELETE'
        normalize_delete(rack_req,s_req)
      when 'POST'
        normalize_post(rack_req,s_req)
      when 'OPTIONS'
        nomalize_options(rack_req,s_req)
      else
        return false
      end

      if s_req.type.nil?
        return false
      end

      return s_req
    end

    def dump_request(request)
      puts "----------Dump Request-------------"
      puts request.request_method
      puts request.path
      request.each do |k,v|
        puts "#{k}:#{v}"
      end
      puts "----------End Dump -------------"
    end

    # For Rails3 applications path given by the rack response is prefixed with
    # a slash. For rails4 this slash is removed, so we ensure that our path
    # always has a forward slash prefix here
    def path_for_rack_request(rack_request)
      if rack_request.path.start_with?('/')
        rack_request.path
      else
        "/#{rack_request.path}"
      end
    end
  end

  class App
    def initialize(path, hostname)
      @servlet = Servlet.new(nil, RackFakeS3::FileStore.new(path), hostname)
    end

    def call(env)
      @servlet.call(env)
    end

    def inspect
      self.class.inspect
    end
  end

  class Server
    def initialize(port,root,hostname)
      @port = port
      @root = root
      @hostname = hostname
    end

    def serve
      ENV['FAKE_S3_ROOT'] = @root
      ENV['FAKE_S3_HOSTNAME'] = @hostname

      @server = Rack::Server.new(:Port => @port, :config => config_ru)

      @server.start
    end

    def config_ru
      File.expand_path("../../../config.ru", __FILE__)
    end

    def shutdown
      @server.shutdown
    end
  end
end
