# be.gs url shortening service
# $Id$
#
# (c) Copyright 2010. Omachonu Ogali <oogali@idlepattern.com>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.

require 'net/http'
require 'uri'
require 'sinatra'
require 'haml'
require 'tokyotyrant'
include TokyoTyrant

def reassemble_url(uri)
  uri.scheme + '://' + uri.host + ((uri.scheme == 'http' and uri.port != 80) or (uri.scheme == 'https' and uri.port != 443) ? (':' + uri.port.to_s) : '') + uri.path
end

def ping(url, limit = 5)
  if limit == 0 then
    false
  end

  # prepend 'http://' if no url scheme is there
  u = (/^(http|https):\/\//.match(url) ? '' : 'http://') + url
  puts 'entering ping() with url: ' + url + ' (' + u + ')'

  # build our uri object, if we can't, bomb out
  uri = URI.parse(u)
  if uri.nil? then
    false
  end

  # no circular loops back to us, bomb out
  if uri.host == 'be.gs' then
    false
  end

  # get our response for this url
  # continue if we get 4xx, we might be passing around a funny 404 page or something
  resp = Net::HTTP.get_response(uri)
  case resp
    when Net::HTTPClientError then
      reassemble_url(uri)
    when Net::HTTPSuccess then
      reassemble_url(uri)
    when Net::HTTPRedirection then
      fetch(resp['location'], limit - 1)
  end
end

def shorten(url)
  # make sure we have a valid url before entering key blocks
  u = ping(url)
  if u then
    # open tokyocabinet database
    db = RDB::new()
    if !db.open('localhost', '19781') then
      halt 500, 'could not connect to database: ' + db.errmsg(db.ecode)
    end

    # does this url exist? if so, return pre-existing key, otherwise store it
    if !db.has_key?(u) then
      i = 0
      power = 2
      base = 36

      # calculate a random number
      # if we go through 10 rounds of rand(), increase the power
      # rinse and repeat until we find a random number not in use
      key = rand(base ** power).to_s(base)
      while !db.has_key?(key) do
        if i >= 10 then
          i = 0
          power += 1
        end

        key = rand(base ** power).to_s(base)
        i += 1
      end

      # store two entries in the database: the url, and the key
      # the url lets us avoid having multiple keys for the same url
      # the key is well, of course, the key
      db.put(u, key)
      db.put(key, u)
      db.close()

      key
    else
      # our url is already in the database, do nothing
      # but close the database to avoid concurrency issues
      key = db.get(u)
      db.close()

      key
    end
  else
    false
  end
end

def do_shorten(url)
  if url.nil? or url.empty? then
    redirect '/'
  end

  key = shorten(url)
  if !key then
    halt 500, 'we don\'t like your url'
  else
    'http://be.gs/' + key
  end
end

def expand(key)
  # create new db instance and open database
  db = RDB::new()
  if !db.open('localhost', '19781') then
    halt 500, 'could not connect to database: ' + db.errmsg(db.ecode)
  end

  # get our url, close db, return result
  url = db.get(key)
  db.close()

  url
end

def do_expand(key)
  if key.nil? or key.empty? then
    redirect '/'
  end

  url = expand(key)
  if url.nil? then
    halt 404, 'your key is invalid'
  else
    url
  end
end

get '/' do
  haml :index
end

get '/source' do
  send_file('main.rb')
end

get '/shorten' do
  do_shorten(params[:url])
end

post '/shorten' do
  do_shorten(params[:url])
end

get '/shorten/*' do
  do_shorten(params['splat'][0])
end

get '/expand' do
  do_expand(params[:key])
end

post '/expand' do
  do_expand(params[:key])
end

get '/expand/*' do
  do_expand(params['splat'][0])
end

get '/*' do
  redirect do_expand(params['splat'][0])
end
