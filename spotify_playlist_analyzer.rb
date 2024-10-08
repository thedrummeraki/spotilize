require 'bundler/setup'
Bundler.require(:default)
require 'fileutils'

def read_auth_token
  File.read('.auth').strip
rescue Errno::ENOENT
  puts "Error: .auth file not found. Please create it with your Spotify bearer token."
  exit 1
end

def fetch_playlist_tracks(playlist_id, auth_token)
  all_tracks = []
  url = if playlist_id == "liked"
    "https://api.spotify.com/v1/me/tracks"
  else
    "https://api.spotify.com/v1/playlists/#{playlist_id}/tracks"
  end
  
  headers = {
    "Authorization" => "Bearer #{auth_token}",
    "Content-Type" => "application/json"
  }

  loop do
    response = HTTParty.get(url, headers: headers)
    data = JSON.parse(response.body)
    all_tracks.concat(data["items"])

    break if data["next"].nil?
    url = data["next"]
  end

  all_tracks
end

def analyze_track(track_id, auth_token)
  url = "https://api.spotify.com/v1/audio-features/#{track_id}"
  headers = {
    "Authorization" => "Bearer #{auth_token}",
    "Content-Type" => "application/json"
  }

  response = HTTParty.get(url, headers: headers)
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

def main
  FileUtils.touch('.analyzed.json') unless File.exist?('.analyzed.json')
  if ARGV.empty?
    puts "Usage: ruby spotify_playlist_analyzer.rb <playlist_id>"
    puts "Use 'liked' as the playlist_id to analyze your liked songs."
    exit 1
  end

  playlist_id = ARGV[0]
  auth_token = read_auth_token

  tracks = nil
  spinner("Loading playlist") do
    tracks = fetch_playlist_tracks(playlist_id, auth_token)
  end
  analyzed_songs = read_analyzed_songs

  puts "Analyzing #{tracks.length} tracks..."
  tracks.each_with_index do |track_item, index|
    track = track_item["track"]
    name = track["name"]
    artist = track["artists"].first["name"]
    track_id = track["id"]

    song_key = "#{name} - #{artist}"

    if analyzed_songs.key?(song_key)
      analysis = analyzed_songs[song_key]
    else
      analysis = analyze_track(track_id, auth_token)
      analyzed_songs[song_key] = analysis
    end

    time_signature = analysis["time_signature"]
    bpm = analysis["tempo"].round

    puts "#{index + 1}/#{tracks.length}: #{song_key} - #{time_signature} - #{bpm}"
  end

  write_analyzed_songs(analyzed_songs)
  puts "Analysis complete. Results saved to .analyzed.json"
end

main
