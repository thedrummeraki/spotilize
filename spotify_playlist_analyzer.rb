require 'bundler/setup'
Bundler.require(:default)

def read_auth_token
  File.read('.auth').strip
rescue Errno::ENOENT
  puts "Error: .auth file not found. Please create it with your Spotify bearer token."
  exit 1
end

def fetch_playlist_tracks(playlist_id, auth_token)
  url = "https://api.spotify.com/v1/playlists/#{playlist_id}/tracks"
  headers = {
    "Authorization" => "Bearer #{auth_token}",
    "Content-Type" => "application/json"
  }

  response = HTTParty.get(url, headers: headers)
  JSON.parse(response.body)["items"]
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

def main
  if ARGV.empty?
    puts "Usage: ruby spotify_playlist_analyzer.rb <playlist_id>"
    exit 1
  end

  playlist_id = ARGV[0]
  auth_token = read_auth_token

  tracks = fetch_playlist_tracks(playlist_id, auth_token)

  tracks.each do |track_item|
    track = track_item["track"]
    name = track["name"]
    artist = track["artists"].first["name"]
    track_id = track["id"]

    analysis = analyze_track(track_id, auth_token)
    time_signature = analysis["time_signature"]
    bpm = analysis["tempo"].round

    puts "#{name} - #{artist} - #{time_signature} - #{bpm}"
  end
end

main
