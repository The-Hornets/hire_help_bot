require 'httparty'
require 'json'
require 'securerandom'
require 'rack/utils'

module VKApi
  BASE = 'https://api.vk.com/method'
  VER  = '5.199'

  class << self
    def send(peer_id, text, keyboard = nil)
      params = auth_params.merge(
        peer_id: peer_id,
        message: text,
        random_id: safe_random_id
      )
      params[:keyboard] = JSON.generate(keyboard) if keyboard

      response = HTTParty.post("#{BASE}/messages.send", body: params)
      parsed = response.parsed_response

      puts "VK messages.send status=#{response.code} body=#{parsed}"
      parsed
    end

    # Ответ на нажатие callback-кнопки (иначе клиент висит в загрузке)
    # HTTParty с Hash может не передать пустой event_data, поэтому сборка тела через Rack
    def send_message_event_answer(user_id:, peer_id:, event_id:, event_data:)
      data =
        if event_data.nil? || event_data == ''
          ''
        elsif event_data.is_a?(String)
          event_data
        else
          JSON.generate(event_data)
        end
      form = auth_params.transform_keys(&:to_s).merge(
        'user_id' => user_id,
        'peer_id' => peer_id,
        'event_id' => event_id.to_s,
        'event_data' => data
      )
      body = Rack::Utils.build_nested_query(form)
      response = HTTParty.post(
        "#{BASE}/messages.sendMessageEventAnswer",
        body: body,
        headers: { 'Content-Type' => 'application/x-www-form-urlencoded; charset=UTF-8' }
      )
      parsed = response.parsed_response
      if parsed.is_a?(Hash) && parsed['error']
        puts "VK sendMessageEventAnswer ERROR #{parsed['error']['error_code']}: #{parsed['error']['error_msg']}"
      else
        puts "VK sendMessageEventAnswer status=#{response.code} body=#{parsed}"
      end
      parsed
    end

    def fetch_json_from_message_attachment(message)
      doc = extract_doc(message)
      return nil unless doc

      url = doc['url'] || resolve_doc_url(doc)
      return nil unless url

      response = HTTParty.get(url)
      return nil unless response.code.to_i == 200

      response.body
    rescue StandardError => e
      puts "VK attachment fetch error: #{e.class} - #{e.message}"
      nil
    end

    private

    def extract_doc(message)
      attachments = message.fetch('attachments', [])
      pair = attachments.find { |item| item['type'] == 'doc' }
      pair && pair['doc']
    end

    def resolve_doc_url(doc)
      owner_id = doc['owner_id']
      doc_id = doc['id']
      access_key = doc['access_key']
      return nil unless owner_id && doc_id

      doc_ref = [owner_id, doc_id, access_key].compact.join('_')
      response = HTTParty.get(
        "#{BASE}/docs.getById",
        query: auth_params.merge(docs: doc_ref)
      )
      parsed = response.parsed_response
      parsed.dig('response', 'items', 0, 'url')
    end

    def auth_params
      {
        access_token: ENV['VK_ACCESS_TOKEN'],
        v: VER
      }
    end

    def safe_random_id
      SecureRandom.random_number((2**31) - 1)
    rescue StandardError
      Time.now.to_i
    end
  end
end