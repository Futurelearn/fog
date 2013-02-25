require 'fog/rackspace'
require 'fog/rackspace/authentication'
require 'fog/cdn'

module Fog
  module CDN
    class Rackspace < Fog::Service

      requires :rackspace_api_key, :rackspace_username
      recognizes :rackspace_auth_url, :persistent, :rackspace_cdn_ssl, :rackspace_region, :rackspace_cdn_url

      request_path 'fog/rackspace/requests/cdn'
      request :get_containers
      request :head_container
      request :post_container
      request :put_container
      request :delete_object
      
      
      module Base
        URI_HEADERS = { 
          "X-Cdn-Ios-Uri" => :ios_uri,
          "X-Cdn-Uri" => :uri,
          "X-Cdn-Streaming-Uri" => :streaming_uri, 
          "X-Cdn-Ssl-Uri" => :ssl_uri
        }.freeze

        def publish_container(container, publish = true)
          enabled = publish ? 'True' : 'False'
          response = put_container(container.key, 'X-Cdn-Enabled' => enabled)
          return {} unless publish
          urls_from_headers(response.headers)
        end
        
        def urls(container)
          begin 
            response = head_container(container.key)
            return {} unless response.headers['X-Cdn-Enabled'] == 'True'
            urls_from_headers response.headers
          rescue Fog::Service::NotFound
            {}
          end
        end
        
        private
        
        def urls_from_headers(headers)
          h = {}
          URI_HEADERS.keys.each do | header |
            key = URI_HEADERS[header]              
            h[key] = headers[header]
          end
          h
        end        
      end

      class Mock
        include Fog::Rackspace::Authentication
        include Base

        def self.data
          @data ||= Hash.new do |hash, key|
            hash[key] = {}
          end
        end

        def self.reset
          @data = nil
        end

        def initialize(options={})
          @rackspace_username = options[:rackspace_username]
        end

        def data
          self.class.data[@rackspace_username]
        end
        
        def purge(object)
          return true if object.is_a? Fog::Storage::Rackspace::File            
          raise Fog::Errors::NotImplemented.new("#{object.class} does not support CDN purging") if object       
        end

        def reset_data
          self.class.data.delete(@rackspace_username)
        end
        
      end

      class Real
        include Fog::Rackspace::Authentication
        include Base

        def initialize(options={})
          @connection_options = options[:connection_options] || {}
          @rackspace_auth_url = options[:rackspace_auth_url]
          @rackspace_cdn_url = options[:rackspace_cdn_url]
          @rackspace_region = options[:rackspace_region] || :dfw
          authenticate(options)
          @enabled = false
          @persistent = options[:persistent] || false

          if endpoint_uri
            @connection = Fog::Connection.new(endpoint_uri, @persistent, @connection_options)
            @enabled = true
          end
        end
        
        def authenticate(options)
          self.send authentication_method, options
        end     
        
        def endpoint_uri(service_endpoint_url=nil)
          return @uri if @uri
          
          url  = @rackspace_cdn_url || service_endpoint_url          
          unless url
            if v1_authentication?
              raise "Service Endpoint must be specified via :rackspace_cdn_url parameter"
            else
              url = @identity_service.service_catalog.get_endpoint(:cloudFilesCDN, @rackspace_region)            
            end
          end          
          
          @uri = URI.parse url
        end      
        
        def purge(object)
          if object.is_a? Fog::Storage::Rackspace::File
            delete_object object.directory.key, object.key
          else
            raise Fog::Errors::NotImplemented.new("#{object.class} does not support CDN purging") if object
          end
          true
        end

        def enabled?
          @enabled
        end

        def reload
          @cdn_connection.reset
        end
        
        def purge(file)
          unless file.is_a? Fog::Storage::Rackspace::File
            raise Fog::Errors::NotImplemented.new("#{object.class} does not support CDN purging")
          end
          
          delete_object file.directory.key, file.key
          true
        end        

        def request(params, parse_json = true)
          begin
            response = @connection.request(params.merge!({
              :headers  => {
                'Content-Type' => 'application/json',
                'X-Auth-Token' => @auth_token
              }.merge!(params[:headers] || {}),
              :host     => endpoint_uri.host,
              :path     => "#{endpoint_uri.path}/#{params[:path]}",
            }))
          rescue Excon::Errors::HTTPStatusError => error
            raise case error
            when Excon::Errors::NotFound
              Fog::Storage::Rackspace::NotFound.slurp(error)
            else
              error
            end
          end
          if !response.body.empty? && parse_json && response.headers['Content-Type'] =~ %r{application/json}
            response.body = Fog::JSON.decode(response.body)
          end
          response
        end
        
        private 
      
        def authenticate_v1(options)
          credentials = Fog::Rackspace.authenticate(options, @connection_options)
          @auth_token = credentials['X-Auth-Token']
          endpoint_uri credentials['X-CDN-Management-Url']          
        end

      end
    end
  end
end
