require 'sinatra'
require 'json'
require 'dotenv/load'
require_relative 'store'
require_relative 'bot'
require 'thread'

# === КОНФИГУРАЦИЯ ===
VK_TOKEN      = ENV['VK_ACCESS_TOKEN']
VK_GROUP_ID   = ENV['VK_GROUP_ID']
VK_CONFIRM    = ENV['VK_CONFIRMATION_CODE']

# Проверка при старте
abort("❌ Нет VK_ACCESS_TOKEN!") unless VK_TOKEN
abort("❌ Нет VK_GROUP_ID!") unless VK_GROUP_ID
abort("❌ Нет VK_CONFIRMATION_CODE!") unless VK_CONFIRM

puts "✅ Бот запущен! Группа: #{VK_GROUP_ID}"

PROCESSED_EVENTS = {}
PROCESSED_EVENTS_MUTEX = Mutex.new
EVENT_TTL_SECONDS = 600
PEER_DISPATCH_LOCKS = Hash.new { |h, k| h[k] = Mutex.new }

def with_peer_lock(peer_id, &block)
  return yield if peer_id.nil?

  PEER_DISPATCH_LOCKS[peer_id].synchronize(&block)
end

def duplicate_event?(event_id)
  return false if event_id.to_s.strip.empty?

  now = Time.now.to_i
  PROCESSED_EVENTS_MUTEX.synchronize do
    # очищаем старые записи, чтобы кэш не рос бесконечно
    PROCESSED_EVENTS.delete_if { |_id, ts| (now - ts) > EVENT_TTL_SECONDS }
    return true if PROCESSED_EVENTS.key?(event_id)

    PROCESSED_EVENTS[event_id] = now
    false
  end
end

# === НАСТРОЙКИ СЕРВЕРА ===
configure do
  set :bind, '0.0.0.0'
  set :port, 4567
  set :host_authorization, {
    permitted_hosts: [
      'localhost',
      '127.0.0.1',
      '.tuna.am'
    ]
  }

  Store.bootstrap!
end

get '/' do
  content_type 'text/plain'
  'VK bot webhook is running'
end

# === ОБРАБОТКА ЗАПРОСОВ ===
post '/webhook' do
  content_type 'text/plain'
  raw_body = request.body.read

  # Лог входящего (для отладки)
  puts "\n📥 ВХОД: #{raw_body[0..200]}..." 

  begin
    data = JSON.parse(raw_body)
  rescue JSON::ParserError
    puts "❌ Не валидный JSON"
    halt 400, { error: 'Invalid JSON' }.to_json
  end

  case data['type']
  when 'confirmation'
    puts "🔐 Подтверждение сервера"
    return VK_CONFIRM

  when 'message_new'
    event_id = data['event_id'].to_s
    if duplicate_event?("mn:#{event_id}")
      puts "♻️ Пропуск дубликата события event_id=#{event_id}"
      return 'ok'
    end

    puts "💬 Новое сообщение"
    msg = data.dig('object', 'message')

    # Игнорируем исходящие сообщения (чтобы бот не отвечал сам себе)
    return 'ok' if msg && msg['out'] == 1

    unless msg
      puts "⚠️ Нет object.message в payload"
      return 'ok'
    end

    peer_id = msg['peer_id']
    raw_text = msg['text']
    has_doc = msg['attachments'].to_a.any? { |a| a['type'] == 'doc' }

    if peer_id.nil?
      puts "⚠️ Нет peer_id в message_new"
      return 'ok'
    end

    # Пустое сообщение без вложения: VK иногда шлёт лишние апдейты; в тренировке это давало «ответ сам себе».
    if raw_text.nil? || raw_text.to_s.strip.empty?
      unless has_doc
        puts '⚠️ Пустой текст без документа — пропуск'
        return 'ok'
      end
    end

    text = raw_text.to_s.strip
    puts "👤 User #{msg['from_id']}: '#{text}'"
    with_peer_lock(peer_id) { Bot.dispatch(msg) }
  end

  'ok'
end