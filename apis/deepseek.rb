require 'httparty'
require 'json'
require 'timeout'

module DeepSeekApi
  API_URL = 'https://api.deepseek.com/v1/chat/completions'
  YANDEX_API_URL = 'https://ai.api.cloud.yandex.net/v1/responses'
  INTERVIEW_SYSTEM_PROMPT = <<~PROMPT.freeze
    Ты технический интервьюер. Пиши по-русски, кратко и по делу.
    Формат интервью:
    1) оцени ответ кандидата,
    2) дай краткое ревью,
    3) предложи улучшение,
    4) задай следующий вопрос.
  PROMPT
  REQUEST_TIMEOUT_SECONDS = [ENV.fetch('LLM_TIMEOUT_SECONDS', '20').to_i, 5].max
  REQUEST_RETRIES = [ENV.fetch('LLM_REQUEST_RETRIES', '1').to_i, 0].max
  INTERVIEW_HISTORY_ITEMS = [ENV.fetch('INTERVIEW_HISTORY_ITEMS', '8').to_i, 2].max
  LLM_MAX_OUTPUT_TOKENS = [ENV.fetch('LLM_MAX_OUTPUT_TOKENS', '280').to_i, 120].max
  # Оценка интервью: у deepseek-v32 в Yandex часто идёт блок reasoning — при малом лимите JSON не помещается.
  INTERVIEW_EVAL_MAX_OUTPUT_TOKENS = [ENV.fetch('INTERVIEW_EVAL_MAX_OUTPUT_TOKENS', '4096').to_i, 1024].max
  YANDEX_OUTPUT_TOKEN_HARD_CAP = 8192
  LLM_INPUT_MAX_CHARS = [ENV.fetch('LLM_INPUT_MAX_CHARS', '900').to_i, 200].max

  class << self
    def chat(messages, temperature: 0.3, max_output_tokens: nil)
      return yandex_chat(messages, temperature: temperature, max_output_tokens: max_output_tokens) if yandex_provider?

      key = ENV['DEEPSEEK_API_KEY'].to_s.strip
      return 'Ошибка DeepSeek: отсутствует DEEPSEEK_API_KEY в .env' if key.empty?

      resp = post_json_with_retries(
        API_URL,
        headers: headers(key),
        body: { model: 'deepseek-chat', messages: messages, temperature: temperature }
      )
      parsed = JSON.parse(resp.body.to_s)
      return "Ошибка DeepSeek HTTP #{resp.code}: #{parsed['error'] || resp.body}" unless resp.code.to_i == 200

      parsed.dig('choices', 0, 'message', 'content') || 'Ошибка API'
    rescue StandardError => e
      "Ошибка DeepSeek: #{e.message}"
    end

    def first_interview_question(topic = nil)
      topic_hint = topic.to_s.strip.empty? ? 'по backend/frontend/devops/data/mobile' : "по теме #{topic}"
      raw = chat(
        [
          {
            role: 'system',
            content: 'Ты технический интервьюер. Задай один короткий вопрос для собеседования. Только вопрос, без ответа и без markdown.'
          },
          { role: 'user', content: "Начни интервью #{topic_hint}." }
        ],
        temperature: 0.4
      )
      return fallback_first_question(topic) if llm_error_text?(raw)

      prepared = raw.to_s.strip
      prepared.empty? ? fallback_first_question(topic) : prepared
    end

    def evaluate_interview_answer(history:, user_answer:)
      safe_history = compact_history(history)
      raw = chat(
        [
          { role: 'system', content: INTERVIEW_SYSTEM_PROMPT }
        ] + safe_history + [
          { role: 'user', content: user_answer },
          {
            role: 'user',
            content: <<~PROMPT
              Оцени ответ как интервьюер и верни строгий JSON:
              {"score": <1-10>, "review": "<до 160 символов>", "improvement": "<до 160 символов>", "next_question": "<до 140 символов>"}
              Только JSON, без markdown и без дополнительного текста.
            PROMPT
          }
        ],
        temperature: 0.2,
        max_output_tokens: INTERVIEW_EVAL_MAX_OUTPUT_TOKENS
      )
      if llm_error_text?(raw)
        warn "[LLM interview] #{raw.to_s[0..900]}"
        return fallback_evaluation
      end

      parse_json_payload(raw)
    end

    private

    def yandex_provider?
      ENV['LLM_PROVIDER'].to_s.strip.downcase == 'yandex'
    end

    def yandex_chat(messages, temperature:, max_output_tokens: nil)
      api_key = ENV['YANDEX_CLOUD_API_KEY'].to_s.strip
      folder_id = ENV['YANDEX_CLOUD_FOLDER_ID'].to_s.strip
      model_name = ENV['YANDEX_CLOUD_MODEL'].to_s.strip

      return 'Ошибка Yandex: отсутствует YANDEX_CLOUD_API_KEY в .env' if api_key.empty?
      return 'Ошибка Yandex: отсутствует YANDEX_CLOUD_FOLDER_ID в .env' if folder_id.empty?
      return 'Ошибка Yandex: отсутствует YANDEX_CLOUD_MODEL в .env' if model_name.empty?

      prepared_model = model_name.start_with?('gpt://') ? model_name : "gpt://#{folder_id}/#{model_name}"
      input_text = messages_to_text(messages)
      cap = max_output_tokens || LLM_MAX_OUTPUT_TOKENS
      parsed = nil

      2.times do |attempt|
        resp = post_json_with_retries(
          YANDEX_API_URL,
          headers: yandex_headers(api_key, folder_id),
          body: {
            model: prepared_model,
            temperature: temperature,
            input: input_text,
            max_output_tokens: cap
          }
        )

        parsed = JSON.parse(resp.body.to_s)
        unless resp.code.to_i == 200
          warn "[Yandex HTTP #{resp.code}] #{resp.body.to_s[0..800]}"
          return "Ошибка Yandex HTTP #{resp.code}: #{parsed['error'] || parsed}"
        end

        output_text = parsed['output_text'].to_s.strip
        return output_text unless output_text.empty?

        extracted = extract_text_from_yandex_output(parsed)
        return extracted if extracted && !extracted.to_s.strip.empty?

        reason = parsed.dig('incomplete_details', 'reason').to_s
        starved = reason.include?('max_output') || only_reasoning_output?(parsed)
        if attempt.zero? && starved && cap < YANDEX_OUTPUT_TOKEN_HARD_CAP
          cap = [cap * 2, YANDEX_OUTPUT_TOKEN_HARD_CAP].min
          warn "[Yandex] повтор запроса: max_output_tokens=#{cap} (incomplete=#{reason.inspect}, only_reasoning=#{only_reasoning_output?(parsed)})"
          next
        end

        break
      end

      warn "[Yandex пустой ответ] keys=#{parsed.keys.inspect} body=#{resp.body.to_s[0..600]}"
      'Ошибка Yandex: пустой ответ модели'
    rescue StandardError => e
      warn "[Yandex исключение] #{e.class}: #{e.message}"
      "Ошибка Yandex: #{e.message}"
    end

    def post_json_with_retries(url, headers:, body:)
      attempts = 0

      begin
        attempts += 1
        HTTParty.post(url, headers: headers, body: body.to_json, timeout: REQUEST_TIMEOUT_SECONDS)
      rescue Net::ReadTimeout, Net::OpenTimeout, Timeout::Error, SocketError, Errno::ECONNRESET, Errno::ETIMEDOUT => e
        retry if attempts <= REQUEST_RETRIES

        raise e
      end
    end

    def llm_error_text?(raw)
      text = raw.to_s.strip
      text.start_with?('Ошибка Yandex:', 'Ошибка DeepSeek:')
    end

    def fallback_first_question(topic)
      normalized_topic = topic.to_s.strip.downcase
      return 'Чем отличается supervised learning от unsupervised learning и когда вы применяете каждый подход?' if normalized_topic.include?('data')
      return 'Чем отличаются процесс и поток, и как это влияет на проектирование backend-сервиса?' if normalized_topic.include?('back')
      return 'Какие шаги вы сделаете, чтобы ускорить загрузку сложной страницы в продакшене?' if normalized_topic.include?('front')
      return 'Как вы организуете CI/CD для сервиса с несколькими окружениями и безопасным деплоем?' if normalized_topic.include?('devops')
      return 'Как вы снижаете потребление батареи и трафика в мобильном приложении?' if normalized_topic.include?('mobile')

      'Расскажите про самый сложный технический проект, в котором вы участвовали, и вашу роль в нем.'
    end

    def fallback_evaluation
      {
        score: 5,
        review: 'Не удалось получить оценку от модели, продолжаем интервью в безопасном режиме.',
        improvement: 'Добавьте больше технической конкретики, терминов и практических примеров.',
        next_question: 'Опишите архитектурное решение, которое вы приняли недавно, и какие компромиссы учли.'
      }
    end

    def yandex_headers(api_key, folder_id)
      {
        'Authorization' => "Bearer #{api_key}",
        'Content-Type' => 'application/json',
        'OpenAI-Project' => folder_id
      }
    end

    def messages_to_text(messages)
      (messages || []).map do |item|
        role = item[:role] || item['role']
        content = (item[:content] || item['content']).to_s.strip
        content = content[0...LLM_INPUT_MAX_CHARS] if content.length > LLM_INPUT_MAX_CHARS
        "#{role}: #{content}"
      end.join("\n")
    end

    def compact_history(history)
      (history || []).last(INTERVIEW_HISTORY_ITEMS)
    end

    def only_reasoning_output?(parsed)
      out = parsed['output']
      return false unless out.is_a?(Array) && !out.empty?

      out.all? { |e| e.is_a?(Hash) && e['type'].to_s == 'reasoning' }
    end

    def extract_text_from_yandex_output(parsed)
      output = parsed['output']
      return nil unless output.is_a?(Array)

      output.each do |entry|
        next unless entry.is_a?(Hash)

        content = entry['content']
        if content.is_a?(Array)
          text_piece = content.find { |c| c.is_a?(Hash) && %w[output_text text].include?(c['type'].to_s) }
          if text_piece && text_piece['text'].to_s.strip != ''
            return text_piece['text'].to_s.strip
          end
        elsif content.is_a?(String) && !content.strip.empty?
          return content.strip
        end

        if entry['text'].to_s.strip != '' && entry['type'].to_s != 'reasoning'
          return entry['text'].to_s.strip
        end
      end

      deep_scan_output_text(output) || deep_scan_output_text(parsed)
    end

    def deep_scan_output_text(node)
      case node
      when Hash
        ty = node['type'].to_s
        if %w[output_text text].include?(ty)
          t = node['text'].to_s.strip
          return t unless t.empty?
        end
        node.each_value { |v| r = deep_scan_output_text(v); return r if r }
      when Array
        node.each { |v| r = deep_scan_output_text(v); return r if r }
      end
      nil
    end

    def headers(key)
      {
        'Authorization' => "Bearer #{key}",
        'Content-Type' => 'application/json'
      }
    end

    def parse_json_payload(raw_text)
      match = raw_text.to_s.match(/\{.*\}/m)
      parsed = JSON.parse(match ? match[0] : raw_text)

      {
        score: parsed['score'].to_i.clamp(1, 10),
        review: blank_fallback(parsed['review'], 'Ревью не получено.'),
        improvement: blank_fallback(parsed['improvement'], 'Добавьте больше конкретики и примеров.'),
        next_question: blank_fallback(parsed['next_question'], 'Расскажите о самой сложной задаче, которую вы недавно решали.')
      }
    rescue StandardError
      {
        score: 5,
        review: raw_text.to_s.strip.empty? ? 'Ответ получен, но формат оценки не распознан.' : raw_text.to_s.strip,
        improvement: 'Добавьте больше конкретики и примеров.',
        next_question: 'Расскажите о самой сложной задаче, которую вы недавно решали.'
      }
    end

    def blank_fallback(value, fallback)
      prepared = value.to_s.strip
      prepared.empty? ? fallback : prepared
    end
  end
end





