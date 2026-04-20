require 'sinatra'
require 'httparty'
require 'json'
require 'dotenv/load'
require 'securerandom'

# === КОНФИГУРАЦИЯ ===
VK_TOKEN      = ENV['VK_ACCESS_TOKEN']
VK_GROUP_ID   = ENV['VK_GROUP_ID']
VK_CONFIRM    = ENV['VK_CONFIRMATION_CODE']
VK_API_V      = '5.199'

# Проверка при старте
abort("❌ Нет VK_ACCESS_TOKEN!") unless VK_TOKEN
abort("❌ Нет VK_GROUP_ID!") unless VK_GROUP_ID
abort("❌ Нет VK_CONFIRMATION_CODE!") unless VK_CONFIRM

puts "✅ Бот запущен! Группа: #{VK_GROUP_ID}"

# === ОТПРАВКА СООБЩЕНИЙ (ИСПРАВЛЕНО) ===
def vk_send_message(peer_id, text)
  puts "📤 Отправка в #{peer_id}: #{text[0..30]}..."

  random_id = begin
    # Основной вариант: случайный int64 в допустимом диапазоне VK.
    SecureRandom.random_number((2**63) - 1)
  rescue => e
    # Fallback для редких platform-specific проблем с random_number/int.
    puts "⚠️ random_id fallback: #{e.class} - #{e.message}"
    Time.now.to_i
  end

  payload = {
    access_token: VK_TOKEN,
    v: VK_API_V,
    peer_id: peer_id,
    message: text,
    random_id: random_id
  }

  # HTTParty автоматически превратит хеш в form-urlencoded, если не указывать JSON
  response = HTTParty.post('https://api.vk.com/method/messages.send', body: payload)
  parsed = response.parsed_response

  puts "📬 VK status: #{response.code}"
  puts "📬 VK body: #{parsed}"

  result = parsed['response']

  if result.is_a?(Integer)
    puts "✅ Успех! Message ID: #{result}"
  elsif result.is_a?(Hash) && result['message_id']
    puts "✅ Успех! Message ID: #{result['message_id']}"
  else
    # Показываем реальную ошибку от ВК
    error_info = parsed['error'] || parsed
    puts "❌ ОШИБКА ВК: #{error_info}"
  end
rescue => e
  puts "💥 КРИТИЧЕСКАЯ ОШИБКА: #{e.class} - #{e.message}"
  puts e.backtrace.first(3).join("\n")
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
end

get '/' do
  content_type 'text/plain'
  'VK bot webhook is running'
end

# === ОБРАБОТКА ЗАПРОСОВ ===
post '/webhook' do
  content_type 'text/plain'
  raw_body = request.body.read
  request.body.rewind
  
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
    puts "💬 Новое сообщение"
    msg = data.dig('object', 'message')
    
    # Игнорируем исходящие сообщения (чтобы бот не отвечал сам себе)
    return 'ok' if msg && msg['out'] == 1

    unless msg
      puts "⚠️ Нет object.message в payload"
      return 'ok'
    end

    peer_id = msg['peer_id']
    text = msg['text']

    if peer_id.nil?
      puts "⚠️ Нет peer_id в message_new"
      return 'ok'
    end

    if text.nil?
      puts "⚠️ Нет text в message_new"
      return 'ok'
    end

    text = text.strip
    puts "👤 User #{msg['from_id']}: '#{text}'"
    
    # Логика эха
    answer = text.empty? ? "👋 Привет!" : "🔁 Вы написали: #{text}"
    vk_send_message(peer_id, answer)
  end

  'ok'
end