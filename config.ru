require 'rubygems'
require 'sinatra'

working = File.expand_path File.dirname(__FILE__)
set :root, working
set :haml, :format => :html5
set :environment, :production
disable :run

require working + '/begs'

log = File.new('sinatra.log', 'a')
$stdout.reopen(log)
$stderr.reopen(log)

run Begs::Application
