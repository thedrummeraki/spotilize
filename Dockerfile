FROM ruby:3.3.3
WORKDIR /code

RUN gem install bundler:2.5.11
COPY Gemfile /code/Gemfile
COPY Gemfile.lock /code/Gemfile.lock

RUN bundle install

COPY . .

ENTRYPOINT ["bundle", "exec"]

CMD ["ruby", "/code/spotify_playlist_analyzer.rb"]

