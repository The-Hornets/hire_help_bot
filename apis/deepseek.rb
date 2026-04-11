require 'httparty'

module DeepSeekApi
  def self.chat(messages)
    resp = HTTParty.post(
      'https://api.deepseek.com/v1/chat/completions',
      headers: { 'Authorization' => "Bearer #{ENV['DEEPSEEK_API_KEY']}", 'Content-Type' => 'application/json' },
      body: { model: 'deepseek-chat', messages: messages }.to_json
    )
    JSON.parse(resp.body).dig('choices', 0, 'message', 'content') || 'Ошибка API'
  end
end