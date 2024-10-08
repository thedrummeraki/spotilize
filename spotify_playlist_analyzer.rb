require 'fileutils'
require 'time'
require 'base64'
require 'optparse'
require 'sinatra/base'
require 'securerandom'
require 'launchy'
require 'httparty'
require 'json'

OPTIONS = {}
ARGV.clone.options do |opts|
  opts.banner = 'Usage: ruby spotify_playlist_analyzer.rb [options] <command> [<args>]'

  opts.on('--id CLIENT_ID', 'Spotify Client ID') do |id|
    OPTIONS[:client_id] = id
  end

  opts.on('--secret CLIENT_SECRET', 'Spotify Client Secret') do |secret|
    OPTIONS[:client_secret] = secret
  end

  opts.on('--first FIRST', 'First N songs to analyze (for a playlist)') do |first|
    OPTIONS[:first] = first.to_i.zero? ? 50 : first.to_i
  end

  opts.on('-h', '--help', 'Display this help') do
    puts opts
    exit
  end

  opts.parse!
end

COMMAND = ARGV.shift

def make_api_request(url, headers, auth_token = nil)
  loop do
    response = HTTParty.get(url, headers: headers)

    if response.code == 401 && auth_token
      puts 'Token expired. Refreshing...'
      new_token = refresh_token(read_refresh_token)
      headers['Authorization'] = "Bearer #{new_token}"
      next
    end

    return response unless response.code == 429

    retry_after = response.headers['Retry-After'].to_i
    puts "Rate limit exceeded. Retrying after #{retry_after} seconds."
    retry_after.downto(1) do |i|
      print "\rTime remaining: #{i} seconds"
      sleep 1
    end
    puts "\nRetrying request..."
  end
end

def read_refresh_token
  File.read('.auth').strip
rescue Errno::ENOENT
  puts 'Error: .auth file not found. Please create it with your Spotify refresh token.'
  exit 1
end

def read_bearer_token
  File.read('.token').strip
rescue Errno::ENOENT
  nil
end

def write_bearer_token(token)
  File.write('.token', token)
end

def refresh_token(refresh_token)
  url = 'https://accounts.spotify.com/api/token'
  client_id = OPTIONS[:client_id] || ENV['SPOTIFY_CLIENT_ID']
  client_secret = OPTIONS[:client_secret] || ENV['SPOTIFY_CLIENT_SECRET']

  if client_id.nil? || client_secret.nil?
    puts 'Error: Spotify Client ID and Client Secret must be provided either as CLI parameters (--id and --secret) or as environment variables (SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET).'
    exit 1
  end

  auth_header = Base64.strict_encode64("#{client_id}:#{client_secret}")
  headers = {
    'Authorization' => "Basic #{auth_header}",
    'Content-Type' => 'application/x-www-form-urlencoded'
  }
  body = {
    grant_type: 'refresh_token',
    refresh_token: refresh_token
  }

  response = HTTParty.post(url, headers: headers, body: body)
  data = JSON.parse(response.body)

  if response.code == 200 && data['access_token']
    write_bearer_token(data['access_token'])
    data['access_token']
  else
    puts "Error refreshing token: #{data['error_description']}"
    exit 1
  end
end

def get_valid_token
  refresh_token = read_refresh_token
  bearer_token = read_bearer_token

  if bearer_token.nil?
    refresh_token(refresh_token)
  else
    bearer_token
  end
end

def fetch_playlist_tracks(playlist_id, first_tracks)
  auth_token = get_valid_token
  all_tracks = []
  url = if playlist_id.downcase == 'liked'
          'https://api.spotify.com/v1/me/tracks'
        else
          "https://api.spotify.com/v1/playlists/#{playlist_id}/tracks"
        end

  headers = {
    'Authorization' => "Bearer #{auth_token}",
    'Content-Type' => 'application/json'
  }

  loop do
    response = make_api_request(url, headers, auth_token)
    data = JSON.parse(response.body)

    if data['error']
      puts "Error: #{data['error']['message']}"
      return []
    end

    all_tracks.concat(data['items']) if data['items']

    break if data['next'].nil?
    break if all_tracks.size >= first_tracks

    url = data['next']
  end

  all_tracks
end

def analyze_track(track_id)
  auth_token = get_valid_token
  url = "https://api.spotify.com/v1/audio-features/#{track_id}"
  headers = {
    'Authorization' => "Bearer #{auth_token}",
    'Content-Type' => 'application/json'
  }

  response = make_api_request(url, headers)
  JSON.parse(response.body)
end

def read_analyzed_songs
  JSON.parse(File.read('.analyzed.json'))
rescue Errno::ENOENT, JSON::ParserError
  {}
end

def write_analyzed_songs(analyzed_songs)
  File.write('.analyzed.json', JSON.pretty_generate(analyzed_songs))
end

def spinner(message)
  spinner = ['|', '/', '-', '\\']
  i = 0
  thread = Thread.new do
    while true
      print "\r#{message} #{spinner[i]}"
      i = (i + 1) % 4
      sleep 0.1
    end
  end
  yield
ensure
  thread.kill
  print "\r#{' ' * (message.length + 2)}\r"
end

class SpotifyAuthApp < Sinatra::Base
  configure do
    set :port, 4567
  end

  def self.run!(client_id:, client_secret:, state:)
    set :client_id, client_id
    set :client_secret, client_secret
    set :state, state
    super()
  end

  get '/callback' do
    if params[:state] == settings.state
      code = params[:code]
      token_url = 'https://accounts.spotify.com/api/token'
      auth_header = Base64.strict_encode64("#{settings.client_id}:#{settings.client_secret}")

      response = ::HTTParty.post(token_url,
                                 headers: {
                                   'Authorization' => "Basic #{auth_header}",
                                   'Content-Type' => 'application/x-www-form-urlencoded'
                                 },
                                 body: {
                                   grant_type: 'authorization_code',
                                   code: code,
                                   redirect_uri: 'http://localhost:4567/callback'
                                 })

      if response.code == 200
        data = JSON.parse(response.body)
        File.write('.auth', data['refresh_token'])
        'Authorization successful! You can now close this window and return to the command line.'
      else
        'Authorization failed. Please try again.'
      end
    else
      'Invalid state parameter. Please try again.'
    end
  end
end

def auth_command
  client_id = OPTIONS[:client_id] || ENV['SPOTIFY_CLIENT_ID']
  client_secret = OPTIONS[:client_secret] || ENV['SPOTIFY_CLIENT_SECRET']

  if client_id.nil? || client_secret.nil?
    puts 'Error: Spotify Client ID and Client Secret must be provided either as CLI parameters (--id and --secret) or as environment variables (SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET).'
    exit 1
  end

  state = SecureRandom.hex(16)
  auth_url = "https://accounts.spotify.com/authorize?client_id=#{client_id}&response_type=code&redirect_uri=http://localhost:4567/callback&scope=user-library-read%20playlist-read-private&state=#{state}"

  puts 'Do you want to open your browser to authorize this script to use your Spotify data?'
  print '> Yes > No (default): '
  answer = gets.chomp.downcase

  if answer == 'yes'
    Launchy.open(auth_url)
  else
    puts 'Please open the following URL in your browser to authorize the application:'
    puts auth_url
  end

  SpotifyAuthApp.run!(client_id: client_id, client_secret: client_secret, state: state)
end

def main
  FileUtils.touch('.analyzed.json') unless File.exist?('.analyzed.json')

  case COMMAND
  when 'auth'
    auth_command
  when 'analyze'
    if ARGV.empty?
      puts 'Error: Please provide a playlist ID after the analyze command.'
      puts 'Usage: ruby spotify_playlist_analyzer.rb [options] analyze <playlist_id>'
      puts "Use 'liked' as the playlist_id to analyze your liked songs."
      exit 1
    end
    playlist_id = ARGV.shift
    analyzed_songs = read_analyzed_songs

    begin
      tracks = nil
      spinner('Loading playlist') do
        tracks = fetch_playlist_tracks(playlist_id, OPTIONS[:first] || 50)
      end

      if tracks.empty?
        puts 'No tracks found or error occurred. Please check the playlist ID and try again.'
        return
      end

      puts "Analyzing #{tracks.length} tracks..."
      tracks.each_with_index do |track_item, index|
        track = track_item['track']
        next unless track # Skip any nil tracks

        track_id = track['id']
        artists = track['artists'].map { |t| t['name'] }.join(', ')
        song_key = "[#{track_id}] #{track['name']} (#{artists})"

        if analyzed_songs.key?(track_id)
          analysis = analyzed_songs[track_id]
        else
          analysis = analyze_track(track_id)
          analyzed_songs[track_id] = analysis
        end

        if analysis['error']
          puts "#{index + 1}/#{tracks.length}: Error analyzing #{song_key}: #{analysis['error']['message']}"
        else
          time_signature = analysis['time_signature']
          bpm = analysis['tempo'].round

          puts "#{index + 1}/#{tracks.length}: #{song_key} - #{time_signature} - #{bpm}"
        end
      end

      puts 'Analysis complete. Results saved to .analyzed.json'
    rescue StandardError => e
      puts "An error occurred: #{e.message}"
      puts e.backtrace
    ensure
      write_analyzed_songs(analyzed_songs)
    end
  end
end

main
