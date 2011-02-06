require 'rubygems'
require 'sinatra'

working = File.dirname(__FILE__)
set :root, working
set :haml, :format => :html5
disable :run

require working + '/begs'

log = File.new('sinatra.log', 'a')
$stdout.reopen(log)
$stderr.reopen(log)

run Begs::Application
