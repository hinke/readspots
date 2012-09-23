require 'rubygems'
require 'uri'
require 'sinatra'
require 'json'
require 'rest_client'
require 'active_support'
require 'geokit'
require 'data_mapper'
require 'active_support'

Geokit::default_units = :kms

class User
  include DataMapper::Resource
  property :id, Serial 
  property :readmill_id, Integer
  property :name, String
  property :access_token, String
end

DataMapper.finalize
DataMapper::Logger.new($stdout, :debug)

configure do
  DataMapper.setup(:default, (ENV["DATABASE_URL"] || {
    :adapter  => 'mysql',
    :host     => 'localhost',
    :username => 'root' ,
    :password => '',
    :database => 'readspots_development'}))
  DataMapper.auto_upgrade!  
end


set :readmill_client_id, "8f92d2cc1a048292df32ed5473c5b2fc"
set :readmill_client_secret, "917774867dc9981c04d78ad7b016b1e6"
set :readmill_redirect, "http://readspots.herokuapp.com/callback/readmill"

get '/' do
  erb :index
end

get '/:id' do |id|
  periods = get_periods(id)
  @slides = transform_to_slides(periods)
  @slides = cleanup_slides(@slides.reverse)

  @username, @avatar = get_user(periods[0]['period']['user']['id'])
  @author, @title, @cover = get_book(periods[0]['period']['reading']['id'])
  @periods = periods.size

  erb :slides
end

get('/static/:filename') { send_file("./static/#{params[:filename]}") }

def get_book(reading_id)
  uri = readmill_uri("/readings/#{reading_id}")
  response = JSON.parse(RestClient.get(uri))
  
  author = response['reading']['book']['author']
  title = response['reading']['book']['title']
  cover = response['reading']['book']['cover_url'].gsub('medium', 'original')

  return author, title, cover
end

def get_user(user_id)
  uri = readmill_uri("/users/#{user_id}")
  response = JSON.parse(RestClient.get(uri))
  return response['user']['fullname'], response['user']['avatar_url'].gsub('medium', 'large')
end

def transform_to_slides(periods)
  slides = []
  
  periods.each do |p|
    locations = flatten_locations(p['period']['locations']['items'])
    locations.each do |l|
      photo, city = get_photo(l.lat,l.lng)
      slides.push({:datestamp => DateTime.parse(p['period']['started_at']).strftime("%A %e %B %Y"), :progress => p['period']['progress'], :photo => photo, :city => city}) unless photo.nil?
    end
  end
  return slides
end

def cleanup_slides(slides)
  puts slides.size
  unique = []
  slides.each do |slide|
    u = true
    unique.each do |test|
      u = false if test[:photo]['id'].eql?(slide[:photo]['id'])
    end
    unique.push(slide) if u
  end
  puts unique.size
  return unique
end

def get_photo(lat, lng)
  uri = eyeem_uri("/albums?geoSearch=nearbyVenues&lat=#{lat}&lng=#{lng}")
  response = JSON.parse(RestClient.get(uri))
  puts uri
  return nil unless response['albums']['total'] > 0
  return nil unless response['albums']['items'][0]['photos']['total'] > 0
  random_index = rand(0..(response['albums']['items'][0]['photos']['items'].size-1))
  city = response['albums']['items'][0]['location']['cityAlbum']['name'] rescue nil
  return response['albums']['items'][0]['photos']['items'][random_index], city
end

def get_insta_photo(lat,lng)
  uri = insta_uri("/media/search?lat=#{lat}&lng=#{lng}&distance=5")
  puts uri
  response = JSON.parse(RestClient.get(uri))
  city = nil
  photo = {'id' => response['data'][0]['id'], 'photoUrl' => response['data'][0]['images']['standard_resolution']['url']}
end

def flatten_locations(locations) 
  radius = 100
  
  bags = []
  locations.collect! {|l| Geokit::LatLng.new(l['location']['lat'], l['location']['lng'])}
  
  locations.each do |l|
    uq = true
    bags.map { |b| uq = false and break if b.distance_to(l) < radius}
    bags.push(l) if uq
  end
  bags.reject! {|b| b.lat == 0.0 || b.lng == 0.0}
  return bags
end

def get_periods(reading_id)
  uri = readmill_uri("/readings/#{reading_id}/periods")
  response = JSON.parse(RestClient.get(uri))
  return response['items']
end

def get_readings(user_id)
  uri = readmill_uri("/users/#{user_id}/readings?states=reading,finished")
  puts uri
  response = JSON.parse(RestClient.get(uri))
  return response['items']
end

def readmill_client_id
  "8f92d2cc1a048292df32ed5473c5b2fc"
end

def readmill_base_url
  "https://api.readmill.com/v2"
end

def readmill_uri(path)
  if path.include?('?')
      uri = "#{readmill_base_url}#{path}&client_id=#{readmill_client_id}"
  else
      uri = "#{readmill_base_url}#{path}?client_id=#{readmill_client_id}"
  end
end

def eyeem_client_id
  "11wyMxx60OAFMT4CeucwpJ38UjOnQCxV"
end

def eyeem_base_url
  "https://www.eyeem.com/api/v2"
end

def eyeem_uri(path)
  uri = "#{eyeem_base_url}#{path}&client_id=#{eyeem_client_id}"
end

def insta_client_id
  "286fe38146b64a81970a157b44d9b7cd"
end

def insta_base_url
  "https://api.instagram.com/v1"
end

def insta_uri(path)
  uri = "#{insta_base_url}#{path}&client_id=#{insta_client_id}"
end

get '/auth/readmill' do
  redirect "http://readmill.com/oauth/authorize?response_type=code&client_id=#{settings.readmill_client_id}&redirect_uri=#{settings.readmill_redirect}&scope=non-expiring"
end

get '/callback/readmill' do
  token_params = {
    :grant_type => 'authorization_code',
    :client_id => settings.readmill_client_id,
    :client_secret => settings.readmill_client_secret,
    :redirect_uri => settings.readmill_redirect,
    :code => params[:code],
    :scope => 'non-expiring'
  }
  resp = JSON.parse(RestClient.post("https://readmill.com/oauth/token.json", token_params).to_str) rescue nil
  
  data = {
    :user => JSON.parse(RestClient.get("https://api.readmill.com/v2/me.json?access_token=#{resp['access_token']}"))
  }

  @readings = get_readings(data[:user]['user']['id'])

  user = User.first_or_create({ :readmill_id => data[:user]['user']['id'] })
  user.name = data[:user]['user']['username']
  user.access_token = resp['access_token']
  @access_token = resp['access_token']
  user.save!
  
  redirect "/picker/#{data[:user]['user']['id']}"
end

get '/picker/:id' do |id|
    @readings = get_readings(id)
    erb :picker
end
  
