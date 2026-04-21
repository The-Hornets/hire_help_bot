FROM ruby:3.3-slim-bookworm

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential \
      libpq-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV LANG=C.UTF-8 \
    BUNDLE_SILENCE_ROOT_WARNING=1

COPY Gemfile Gemfile.lock ./

# Gemfile.lock с Windows-платформой: в Linux-сборке компилируем гемы из исходников (в т.ч. pg).
RUN bundle config set force_ruby_platform true && \
    bundle install

COPY . .

EXPOSE 4567

CMD ["bundle", "exec", "rackup", "config.ru", "-o", "0.0.0.0", "-p", "4567"]
