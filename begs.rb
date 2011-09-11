require 'rubygems'
require 'sinatra'
require 'haml'
require 'redis'
require 'json'
require 'net/https'
require 'logger'
require 'yaml'

module Begs
  class Application < Sinatra::Base
    @redis
    @log
    @opts

    def Begs.reassemble_url(uri)
      nil unless uri
      uri.scheme + '://' + uri.host + ((uri.scheme == 'http' and uri.port != 80) or (uri.scheme == 'https' and uri.port != 443) ? (':' + uri.port.to_s) : '') + uri.request_uri + (uri.fragment.nil? ? '' : ('#' + uri.fragment))
    end

    def initialize
      super #
      @log = Logger.new(STDERR)
      @log.level = Logger::INFO

      @opts = {}
      @opts.merge! YAML.load_file('/home/missnglnk/www/be.gs/begs.yml')
      self.connect
    end

    def connect
      @redis.quit unless !@redis rescue nil

      @redis = Redis.new
      @log.info @opts.inspect
      if @opts[:redis] and @opts[:redis][:passwd]
        @redis.auth @opts[:redis][:passwd]
      end

      @redis.ping
      @log.info("Connected to redis")
    end

    def ping(url, limit = 5)
      url = URI.decode(url) rescue nil
      nil unless url
      @log.debug "Entered ping for #{url}"

      # we've exhausted 5 levels of redirection
      if limit <= 0
        @log.error "Redirection limit reached on #{url}"
        return nil
      end

      # prepend http:// if no scheme given, and parse URL
      uri = URI.parse((/^http[s]*\:\/\//.match(url) ? '' : 'http://') + url) rescue nil
      if !uri
        @log.error "Invalid URL: #{url}"
        return nil
      end

      # don't try to loop on ourselves
      nil unless uri.host != 'be.gs'

      h = Net::HTTP.new(uri.host, uri.port)
      h.read_timeout = 5
      if !h
        @log.error "Could not create HTTP object for #{uri.host}:#{uri.port}"
        return nil
      end

      # enable ssl because silly Net::HTTP won't do it for us
      h.use_ssl = (uri.scheme == 'https')

      headers = { 'User-Agent' => 'be.gs/20110206 (be.gs url shortener; +http://be.gs)' }
      req = Net::HTTP::Get.new(uri.request_uri, headers)
      req.set_range 0, 2048
      resp = h.request req

      if !resp
        @log.error "Could not do a request for #{uri.scheme}://#{uri.host}:#{uri.port}#{uri.request_uri}"
        return nil
      end

      case resp
        when Net::HTTPClientError, Net::HTTPSuccess then
          Begs.reassemble_url(uri)
        when Net::HTTPRedirection then
          ping(resp['location'], limit - 1)
      end
    end

    def gen_rand_key(power, base = 36)
      'begs::url:%s' % rand(base ** power).to_s(base)
    end

    def new_key
      i = 0
      power = 2

      # this is scary, we could potentially loop for a very long time
      key = gen_rand_key(power)
      while self.exists(key) do
        if i >= 20
          i = 0
          power += 1
        end

        key = gen_rand_key(power)
        i += 1
      end

      key
    end

    def shorten(url, rkey = nil)
      nil unless url

      key = self.get('begs::url:' + url) rescue nil
      return key.split(/:/)[3] unless key.nil?

      u = self.ping(url)
      return nil unless u

      key = self.get('begs::url:' + u) rescue nil
      if !key
        if rkey and rkey.length < 32
          rkey = "begs::url:#{rkey}"
          key = rkey unless self.exists rkey rescue nil
        end

        key = self.new_key unless key

        if !key
          @log.error "Could not acquire a new key"
          return nil
        end

        self.set "#{key}", ({ 'url' => u, 'created' => Time.now.to_i }).to_json
        self.set "#{key}.count", 0
        self.set "begs::url:#{u}", key
      end

      key.split(/:/)[3]
    end

    def expand(key)
      self.get "begs::url:#{key}" rescue nil
    end

    def reconnect_if_needed
      @redis.ping rescue self.connect
    end

    def exists(key)
      self.reconnect_if_needed
      @redis.exists key
    end

    def get(key)
      self.reconnect_if_needed
      @redis.get key
    end

    def set(key, val)
      self.reconnect_if_needed
      @redis.set key, val
    end

    def incr(key)
      self.reconnect_if_needed
      @redis.incr key
    end

    helpers do
      def do_shorten(url, rkey = nil)
        key = self.shorten url, rkey
        halt 500, "we don't like your url" unless key
        'http://be.gs/' + key
      end

      def do_expand(key)
        'http://be.gs/?lol=whut' unless !key and !key.empty?

        url = self.expand key
        if !url
          halt 404, "URL not found"
          nil
        end

        (JSON.parse url)['url'] rescue 'http://be.gs/?lol=whut'
      end

      def inc_hit_count(key)
        k = "begs::url:#{key}"
        self.incr("#{k}.count") unless !self.exists k rescue false
      end
    end

    get '/' do
      content_type 'text/html'
      haml :index
    end

    get %r{/css/(default|reset|formalize).css} do |css|
      content_type 'text/css'
      sass css.to_sym
    end

    get %r{/img/(.*)} do |img|
      fn = File.join 'public/img/', img
      return 'URL not found' if !File.exists? fn
      File.open(fn).read
    end

    get %r{/js/(.*).js} do |js|
      fn = File.join 'public/js/', "#{js}.js"
      return 'URL not found' if !File.exists? fn
      content_type 'application/javascript'
      File.open(fn).read
    end

    get '/shorten' do
      do_shorten params[:url], params[:key]
    end

    get '/shorten/*' do
      do_shorten request.fullpath[1..-1].split('/')[1..-1].join('/')
    end

    post '/shorten' do
      do_shorten params[:url], params[:key]
    end

    get '/expand' do
      do_expand params[:key]
    end

    get '/expand/*' do
      do_expand params['splat']
    end

    post '/expand' do
      do_expand params[:key]
    end

    get '/*' do
      inc_hit_count(params['splat'])
      redirect do_expand(params['splat'])
    end
  end
end
