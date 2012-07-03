require "warden/network"
require "warden/event_emitter"
require "warden/logger"
require "warden/errors"
require "warden/container"
require "warden/pool/network"
require "warden/pool/port"
require "warden/pool/uid"

require "eventmachine"
require "warden/protocol"

require "fileutils"
require "fiber"

module Warden

  module Server

    def self.config
      @config
    end

    def self.default_unix_domain_path
      "/tmp/warden.sock"
    end

    def self.default_unix_domain_permissions
      0755
    end

    def self.unix_domain_path
      @unix_domain_path
    end

    def self.unix_domain_permissions
      @unix_domain_permissions
    end

    def self.default_container_klass
      ::Warden::Container::Insecure
    end

    def self.container_klass
      @container_klass
    end

    def self.default_container_grace_time
      5 * 60 # 5 minutes
    end

    def self.container_grace_time
      @container_grace_time
    end

    def self.setup_server(config = nil)
      config ||= {}
      @unix_domain_path = config.delete("unix_domain_path") { default_unix_domain_path }
      @unix_domain_permissions = config.delete("unix_domain_permissions") { default_unix_domain_permissions }
      @container_klass = config.delete("container_klass") { default_container_klass }
      @container_grace_time = config.delete("container_grace_time") { default_container_grace_time }
    end

    def self.setup_logger(config = nil)
      config ||= {}
      Warden::Logger.setup_logger(config)
    end

    def self.setup_network(config = nil)
      config ||= {}

      network_start_address = Network::Address.new(config["pool_start_address"] || "10.254.0.0")
      network_size = config["pool_size"] || 64
      network_pool = Pool::Network.new(network_start_address, network_size)
      container_klass.network_pool = network_pool

      port_pool = Pool::Port.new
      container_klass.port_pool = port_pool
    end

    def self.setup_user(config = nil)
      config ||= {}

      uid_start_uid = config["pool_start_uid"] || 10000
      uid_size = config["pool_size"] || 64
      uid_pool = Pool::Uid.new(uid_start_uid.to_i, uid_size.to_i)
      container_klass.uid_pool = uid_pool
    end

    def self.setup(config = {})
      @config = config

      setup_server config["server"]
      setup_logger config["logging"]
      setup_network config["network"]
      setup_user config["user"]
    end

    def self.run!
      ::EM.epoll
      ::EM.run {
        f = Fiber.new do
          container_klass.setup(self.config)

          FileUtils.rm_f(unix_domain_path)
          ::EM.start_unix_domain_server(unix_domain_path, ClientConnection)

          # This is intentionally blocking. We do not want to start accepting
          # connections before permissions have been set on the socket.
          FileUtils.chmod(unix_domain_permissions, unix_domain_path)

          # Let the world know Warden is ready for action.
          Logger.logger.info("Listening on #{unix_domain_path}, and ready for action.")
        end

        f.resume
      }
    end

    class ClientConnection < ::EM::Connection

      CRLF = "\r\n"

      include EventEmitter
      include Logger

      def post_init
        @blocked = false
        @closing = false
        @requests = []
        @buf = ""
      end

      def unbind
        f = Fiber.new { emit(:close) }
        f.resume
      end

      def close
        close_connection_after_writing
        @closing = true
      end

      def closing?
        !! @closing
      end

      def send_response(obj)
        data = obj.wrap.encode.to_s
        send_data data.length.to_s + "\r\n"
        send_data data + "\r\n"
      end

      def send_error(err)
        send_response Protocol::ErrorResponse.new(:message => err.message)
      end

      def receive_data(data = nil)
        @buf << data if data

        crlf = @buf.index(CRLF)
        if crlf
          begin
            length = Integer(@buf[0...crlf])
            protocol_length = crlf + 2 + length + 2
            if @buf.length >= protocol_length
              payload = @buf[crlf + 2, length]

              # Trim buffer
              @buf = @buf[protocol_length..-1]

              # Unwrap request
              request = Protocol::WrappedRequest.decode(payload).request
              receive_request(request)
            end
          rescue => e
            close_connection_after_writing
            warn "Disconnected client after error parsing request: #{e} (#{e.backtrace.first})"
          end
        end
      end

      def receive_request(req = nil)
        @requests << req if req

        # Don't start new request when old one hasn't finished, or the
        # connection is about to be closed.
        return if @blocked or @closing

        request = @requests.shift

        return if request.nil?

        debug request

        f = Fiber.new {
          begin
            @blocked = true
            process(request)

          ensure
            @blocked = false

            # Resume processing the input buffer
            ::EM.next_tick { receive_request }
          end
        }

        f.resume
      end

      def process(request)
        case request
        when Protocol::PingRequest
          response = request.create_response
          send_response(response)

        when Protocol::ListRequest
          response = request.create_response
          response.handles = Server.container_klass.registry.keys.map(&:to_s)
          send_response(response)

        when Protocol::EchoRequest
          response = request.create_response
          response.message = request.message
          send_response(response)

        when Protocol::CreateRequest
          container = Server.container_klass.new
          container.register_connection(self)
          response = container.dispatch(request)
          send_response(response)

        else
          if request.respond_to?(:handle)
            container = find_container(request.handle)
            process_container_request(request, container)
          else
            raise WardenError.new("Unknown request: #{request.class.name.split("::").last}")
          end
        end
      rescue WardenError => e
        send_error e
      end

      def process_container_request(request, container)
        response = container.dispatch(request)
        send_response(response)
      end

      def process_ping(_)
        "pong"
      end

      def process_create(request)
        request.require_arguments { |n| (n == 1) || (n == 2) }
      end

      def process_stop(request)
        request.require_arguments { |n| n == 2 }
        container.stop
      end

      def process_destroy(request)
        request.require_arguments { |n| n == 2 }
        container = find_container(request[1])
        container.destroy
      end

      def process_spawn(request)
        request.require_arguments { |n| (n == 3) || (n == 4) }
        container = find_container(request[1])

        if (request.length == 4) && !request[3].kind_of?(Hash)
          raise WardenError.new("Options must be a hash")
        end

        container.spawn(*request.slice(2, 2))
      end

      def process_link(request)
        request.require_arguments { |n| n == 3 }
        container = find_container(request[1])
        container.link(request[2])
      end

      def process_run(request)
        request.require_arguments { |n| (n == 3) || (n == 4) }
        container = find_container(request[1])

        if (request.length == 4) && !request[3].kind_of?(Hash)
          raise WardenError.new("Options must be a hash")
        end

        container.run(*request.slice(2, 2))
      end

      def process_net(request)
        request.require_arguments { |n| n >= 3 }
        container = find_container(request[1])

        case request[2]
        when "in"
          request.require_arguments { |n| n == 3 || n == 4 }
          container.net_in(request[3])
        when "out"
          request.require_arguments { |n| n == 4 }
          container.net_out(request[3])
        else
          raise WardenError.new("invalid argument")
        end
      end

      def process_copy(request)
        request.require_arguments {|n| (n == 5) || (n == 6) }
        container = find_container(request[1])

        unless (request[2] == "in") || (request[2] == "out")
          raise WardenError.new("Invalid direction, must be 'in' or 'out'.")
        end

        container.copy(*request.slice(2, request.length - 2))
      end

      def process_limit(request)
        request.require_arguments { |n| n >= 3 }
        container = find_container(request[1])

        if request.length > 3
          container.set_limit(request[2], request.slice(3, request.length - 3))
        else
          container.get_limit(request[2])
        end
      end

      def process_info(request)
        request.require_arguments { |n| n == 2 }
        container = find_container(request[1])
        container.info
      end

      def process_list(request)
      end

      def process_stream(request)
        request.require_arguments { |n| n == 3 }
        container = find_container(request[1])

        container.stream(request[2]) { |name, data|
          send_response([name, data])
        }

        []
      end

      protected

      def find_container(handle)
        Server.container_klass.registry[handle].tap do |container|
          raise WardenError.new("unknown handle") if container.nil?

          # Let the container know that this connection references it
          container.register_connection(self)
        end
      end

      class Request < Array

        def require_arguments
          unless yield(size)
            raise WardenError.new("invalid number of arguments")
          end
        end
      end
    end
  end
end
