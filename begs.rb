require 'rubygems'
require 'sinatra'
require 'haml'
require 'redis'
require 'json'
require 'net/https'
require 'logger'

module Begs
  class Application < Sinatra::Base
    @redis = nil
    @log = nil

    def Begs.reassemble_url(uri)
      nil unless uri
      uri.scheme + '://' + uri.host + ((uri.scheme == 'http' and uri.port != 80) or (uri.scheme == 'https' and uri.port != 443) ? (':' + uri.port.to_s) : '') + uri.request_uri + (uri.fragment.nil? ? '' : ('#' + uri.fragment))
    end

    def initialize
      super #
      @log = Logger.new(STDERR)
      @log.level = Logger::INFO
      self.connect
    end

    def connect
      @redis.quit unless !@redis rescue nil

      @redis = Redis.new
      @redis.ping
      @log.info("Connected to redis")
    end

    def ping(url, limit = 5)
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
      if !h
        @log.error "Could not create HTTP object for #{uri.host}:#{uri.port}"
        return nil
      end

      # enable ssl because silly Net::HTTP won't do it for us
      h.use_ssl = (uri.scheme == 'https')

      headers = { 'User-Agent' => 'be.gs/20110206 (be.gs url shortener; +http://be.gs)' }
      resp = h.head uri.request_uri, headers rescue nil

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
        if i >= 10
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

        return nil unless key
        self.set "#{key}", ({ 'url' => u, 'created' => Time.now.to_i }).to_json
        self.set "#{key}.count", 0
        self.set "begs::url:#{u}", key
      end

      key.split(/:/)[3]
    end

    def expand(key)
      self.get "begs::url:#{key}" rescue nil
    end

    def exists(key)
      @redis.ping rescue self.connect
      @redis.exists key
    end

    def get(key)
      @redis.ping rescue self.connect
      @redis.get key
    end

    def set(key, val)
      @redis.ping rescue self.connect
      @redis.set key, val
    end

    def incr(key)
      @redis.ping rescue self.connect
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

        (JSON.parse url)['url']
      end

      def inc_hit_count(key)
        k = "begs::url:#{key}"
        self.incr("#{k}.count") unless !self.exists k rescue false
      end
    end

    get '/' do
      haml :index
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
