require_relative 'store'
require_relative 'apis/vk'
require_relative 'apis/deepseek'
require 'json'

module Bot
  MAIN_KEYBOARD = {
    one_time: false,
    buttons: [
      [{ action: { type: 'text', label: 'Тренировка' }, color: 'primary' }],
      [{ action: { type: 'text', label: 'Загрузить вопросы' }, color: 'secondary' }],
      [{ action: { type: 'text', label: 'Живое интервью' }, color: 'positive' }],
      [{ action: { type: 'text', label: 'Статистика' }, color: 'secondary' }]
    ]
  }.freeze
  # Одна кнопка «Меню» под полем ввода: не мешает набору ответа, но держит выход в главное меню.
  MENU_REPLY_KEYBOARD = {
    one_time: false,
    buttons: [
      [{ action: { type: 'text', label: 'Меню' }, color: 'secondary' }]
    ]
  }.freeze
  INLINE_NAV_KEYBOARD = {
    inline: true,
    buttons: [
      [
        { action: { type: 'text', label: 'Дальше' }, color: 'primary' },
        { action: { type: 'text', label: 'Меню' }, color: 'secondary' }
      ]
    ]
  }.freeze
  INTERVIEW_RANDOM_INLINE_KEYBOARD = {
    inline: true,
    buttons: [
      [
        { action: { type: 'text', label: 'Рандом' }, color: 'primary' }
      ]
    ]
  }.freeze
  INTERVIEW_TOPIC_INLINE_KEYBOARD = {
    inline: true,
    buttons: [
      [
        { action: { type: 'text', label: 'Backend' }, color: 'primary' },
        { action: { type: 'text', label: 'Frontend' }, color: 'primary' }
      ],
      [
        { action: { type: 'text', label: 'DevOps' }, color: 'primary' },
        { action: { type: 'text', label: 'Mobile' }, color: 'primary' }
      ],
      [
        { action: { type: 'text', label: 'DataScience' }, color: 'primary' },
        { action: { type: 'text', label: 'Рандом' }, color: 'secondary' }
      ]
    ]
  }.freeze
  TRAINING_CATEGORY_INLINE_KEYBOARD = {
    inline: true,
    buttons: [
      [
        { action: { type: 'text', label: 'Backend' }, color: 'primary' },
        { action: { type: 'text', label: 'Frontend' }, color: 'primary' }
      ],
      [
        { action: { type: 'text', label: 'DevOps' }, color: 'primary' },
        { action: { type: 'text', label: 'Mobile' }, color: 'primary' }
      ],
      [
        { action: { type: 'text', label: 'DataScience' }, color: 'primary' }
      ]
    ]
  }.freeze
  INTERVIEW_MENU_INLINE_KEYBOARD = {
    inline: true,
    buttons: [
      [
        { action: { type: 'text', label: 'Меню' }, color: 'secondary' }
      ]
    ]
  }.freeze
  class << self
    def dispatch(message)
      text = message['text'].to_s.strip
      vk_id = message['from_id']
      peer_id = message['peer_id']
      return if vk_id.nil? || peer_id.nil?

      user = Store.upsert_user(vk_id)

      state_payload = Store.user_state(vk_id)
      state = state_payload[:state]
      data = state_payload[:data] || {}

      return show_menu(vk_id, peer_id, 'Главное меню') if start_command?(text)
      if menu_command?(text)
        abandon_current_activity!(user, state, data)
        return show_menu(vk_id, peer_id, 'Возвращаю в меню')
      end
      # Во время интервью нижняя reply-клавиатура («Тренировка» и т.д.) не должна рвать сессию — иначе случайное нажатие сбрасывает вопрос.
      if global_menu_selection?(text) && !interview_blocking_state?(state)
        abandon_current_activity!(user, state, data)
        Store.set_user_state(vk_id, 'menu')
        handle_menu(user, text, peer_id)
        return
      end

      case state
      when 'menu' then handle_menu(user, text, peer_id)
      when 'training_category' then handle_training_category(user, text, peer_id)
      when 'training_answer' then handle_training_answer(user, text, peer_id, data)
      when 'upload_mode' then handle_upload_mode(user, text, peer_id)
      when 'upload_manual_category' then handle_upload_manual_category(user, text, peer_id)
      when 'upload_manual_question' then handle_upload_manual_question(user, text, peer_id, data)
      when 'upload_manual_answer' then handle_upload_manual_answer(user, text, peer_id, data)
      when 'upload_manual_hint' then handle_upload_manual_hint(user, text, peer_id, data)
      when 'upload_file_wait' then handle_upload_file(user, message, peer_id)
      when 'live_interview_topic' then handle_live_interview_topic(user, text, peer_id)
      when 'live_interview' then handle_live_interview(user, text, peer_id, data)
      else
        show_menu(vk_id, peer_id, 'Состояние сброшено: открыл главное меню.')
      end
    rescue StandardError => e
      puts "Bot dispatch error: #{e.class} - #{e.message}"
      VKApi.send(peer_id, 'Произошла ошибка обработки. Отправьте "Начать" для возврата в меню.', MAIN_KEYBOARD)
    end

    private

    # Inline type: 'text' — нажатие приходит как message_new (как у кнопок выбора категории).
    # Callback (type: 'callback') требует события message_event в настройках Callback API; без него кнопки «крутятся».
    def training_text_action(label)
      { type: 'text', label: label }
    end

    def training_inline_keyboard(_question_id = nil)
      {
        inline: true,
        buttons: [
          [
            { action: training_text_action('Подсказка'), color: 'secondary' },
            { action: training_text_action('Показать ответ'), color: 'secondary' }
          ],
          [
            { action: training_text_action('Дальше'), color: 'primary' },
            { action: training_text_action('Меню'), color: 'secondary' }
          ]
        ]
      }
    end

    def training_hint_shown_keyboard(_question_id = nil)
      {
        inline: true,
        buttons: [
          [
            { action: training_text_action('Показать ответ'), color: 'secondary' }
          ],
          [
            { action: training_text_action('Дальше'), color: 'primary' },
            { action: training_text_action('Меню'), color: 'secondary' }
          ]
        ]
      }
    end

    def training_answer_shown_keyboard(_question_id = nil)
      {
        inline: true,
        buttons: [
          [
            { action: training_text_action('Дальше'), color: 'primary' },
            { action: training_text_action('Меню'), color: 'secondary' }
          ]
        ]
      }
    end

    def handle_menu(user, text, peer_id)
      normalized = normalize(text)
      case normalized
      when 'тренировка'
        categories = Store.categories
        if categories.empty?
          VKApi.send(peer_id, 'Категории пока пустые. Добавьте вопросы через "Загрузить вопросы".', MAIN_KEYBOARD)
          return
        end

        category_lines = categories.map { |cat| "- #{cat[:name]}" }.join("\n")
        Store.set_user_state(user[:vk_id], 'training_category')
        VKApi.send(peer_id, "Выберите категорию:\n#{category_lines}", TRAINING_CATEGORY_INLINE_KEYBOARD)
      when 'загрузить вопросы'
        Store.set_user_state(user[:vk_id], 'upload_mode')
        VKApi.send(
          peer_id,
          "Выберите способ загрузки:\n1) Вручную\n2) Файл JSON\n\nНапишите: Вручную, Файл или Меню",
          reply_keyboard(['Вручную', 'Файл', 'Меню'], columns: 2, one_time: true)
        )
      when 'живое интервью'
        Store.set_user_state(user[:vk_id], 'live_interview_topic')
        VKApi.send(
          peer_id,
          'Выберите тему интервью:',
          INTERVIEW_TOPIC_INLINE_KEYBOARD
        )
      when 'статистика'
        show_stats(user, peer_id)
      else
        VKApi.send(peer_id, "Доступные режимы:\n- Тренировка\n- Загрузить вопросы\n- Живое интервью\n- Статистика", MAIN_KEYBOARD)
      end
    end

    def handle_training_category(user, text, peer_id)
      category = Store.category_by_text(normalize_training_category_input(text))
      unless category
        VKApi.send(peer_id, 'Не нашел категорию. Введите корректное название, например Backend.', MAIN_KEYBOARD)
        return
      end

      session = Store.start_session(user_id: user[:id], mode: 'training', category_id: category[:id])
      question = Store.random_question(category[:id])
      unless question
        VKApi.send(peer_id, 'В этой категории пока нет вопросов. Попробуйте другую.', MAIN_KEYBOARD)
        return
      end

      Store.update_session_question(session[:id], question[:id])
      Store.set_user_state(
        user[:vk_id],
        'training_answer',
        {
          session_id: session[:id],
          category_id: category[:id],
          question_id: question[:id],
          answered: false,
          hint_shown: false,
          answer_shown: false
        }
      )

      VKApi.send(
        peer_id,
        "Категория: #{category[:name]}\nВопрос:\n#{question[:question_text]}",
        training_inline_keyboard(question[:id])
      )
    end

    def handle_training_answer(user, text, peer_id, data)
      return if text.to_s.strip.empty?

      session_id = data['session_id'] || data[:session_id]
      category_id = data['category_id'] || data[:category_id]
      question_id = data['question_id'] || data[:question_id]
      answered = data['answered'] || data[:answered]
      hint_shown = data['hint_shown'] || data[:hint_shown]
      answer_shown = data['answer_shown'] || data[:answer_shown]
      question = Store.question_by_id(question_id)
      unless question
        show_menu(user[:vk_id], peer_id, 'Вопрос не найден, возвращаю в меню.')
        return
      end

      if next_command?(text)
        send_next_training_question(user, peer_id, session_id, category_id, question_id)
        return
      end

      if training_hint_command?(text)
        message_text = if hint_shown
                         'Подсказка уже показана выше. Нажмите "Дальше" или ответьте на вопрос.'
                       elsif question[:hint_text].to_s.strip.empty?
                         'Для этого вопроса подсказка не задана.'
                       else
                         "Подсказка:\n#{question[:hint_text]}"
                       end
        Store.set_user_state(
          user[:vk_id],
          'training_answer',
          {
            session_id: session_id,
            category_id: category_id,
            question_id: question_id,
            answered: answered,
            hint_shown: true,
            answer_shown: answer_shown
          }
        )
        VKApi.send(peer_id, message_text, training_hint_shown_keyboard(question_id))
        return
      end

      if training_show_answer_command?(text)
        message_text = if answer_shown
                         'Правильный ответ уже показан выше. Нажмите "Дальше" для следующего вопроса.'
                       else
                         answer_message(question)
                       end
        Store.set_user_state(
          user[:vk_id],
          'training_answer',
          {
            session_id: session_id,
            category_id: category_id,
            question_id: question_id,
            answered: true,
            hint_shown: hint_shown,
            answer_shown: true
          }
        )
        VKApi.send(peer_id, message_text, training_answer_shown_keyboard(question_id))
        return
      end

      if answered
        VKApi.send(peer_id, 'Выберите действие:', training_answer_shown_keyboard(question_id))
        return
      end

      score, feedback = evaluate_answer(text, question[:answer_text].to_s)
      answer_text = answer_message(question)

      Store.record_attempt(
        session_id: session_id,
        user_id: user[:id],
        question_id: question[:id],
        user_answer: text.to_s,
        score: score,
        feedback: feedback
      )
      Store.set_user_state(
        user[:vk_id],
        'training_answer',
        {
          session_id: session_id,
          category_id: category_id,
          question_id: question_id,
          answered: true,
          hint_shown: hint_shown,
          answer_shown: true
        }
      )

      VKApi.send(peer_id, answer_text, training_answer_shown_keyboard(question_id))
    end

    def send_next_training_question(user, peer_id, session_id, category_id, current_question_id)
      question = Store.random_question(category_id, exclude_question_id: current_question_id)
      unless question
        categories = Store.categories
        category_lines = categories.map { |cat| "- #{cat[:name]}" }.join("\n")
        Store.set_user_state(user[:vk_id], 'training_category')
        VKApi.send(
          peer_id,
          "В этой категории пока нет других вопросов.\nДобавьте еще вопросы через 'Загрузить вопросы' или выберите другую категорию:\n#{category_lines}",
          TRAINING_CATEGORY_INLINE_KEYBOARD
        )
        return
      end

      Store.update_session_question(session_id, question[:id])
      Store.set_user_state(
        user[:vk_id],
        'training_answer',
        {
          session_id: session_id,
          category_id: category_id,
          question_id: question[:id],
          answered: false,
          hint_shown: false,
          answer_shown: false
        }
      )
      VKApi.send(peer_id, "Следующий вопрос:\n#{question[:question_text]}", training_inline_keyboard(question[:id]))
    end

    def handle_upload_mode(user, text, peer_id)
      normalized = normalize(text)
      if normalized == 'вручную'
        Store.set_user_state(user[:vk_id], 'upload_manual_category')
        VKApi.send(peer_id, 'Введите категорию для нового вопроса (например Backend).', MAIN_KEYBOARD)
      elsif normalized == 'файл'
        Store.set_user_state(user[:vk_id], 'upload_file_wait')
        VKApi.send(peer_id, "Отправьте JSON-файл или вставьте JSON-массив.\nФормат объекта: {\"category\":\"Backend\",\"question\":\"...\",\"answer\":\"...\",\"hint\":\"...\"}", MAIN_KEYBOARD)
      else
        VKApi.send(
          peer_id,
          'Напишите: Вручную, Файл или нажмите «Меню».',
          reply_keyboard(['Вручную', 'Файл', 'Меню'], columns: 2, one_time: true)
        )
      end
    end

    def handle_upload_manual_category(user, text, peer_id)
      category = Store.find_or_create_category(text)
      unless category
        VKApi.send(peer_id, 'Категория не распознана. Попробуйте еще раз.', MAIN_KEYBOARD)
        return
      end

      Store.set_user_state(
        user[:vk_id],
        'upload_manual_question',
        { category_id: category[:id], category_name: category[:name] }
      )
      VKApi.send(peer_id, "Категория '#{category[:name]}' выбрана. Отправьте текст вопроса.", MAIN_KEYBOARD)
    end

    def handle_upload_manual_question(user, text, peer_id, data)
      if text.to_s.strip.empty?
        VKApi.send(peer_id, 'Вопрос пустой. Отправьте текст вопроса.', MAIN_KEYBOARD)
        return
      end

      Store.set_user_state(
        user[:vk_id],
        'upload_manual_answer',
        data.merge('question_text' => text.to_s.strip)
      )
      VKApi.send(peer_id, 'Отправьте правильный ответ.', MAIN_KEYBOARD)
    end

    def handle_upload_manual_answer(user, text, peer_id, data)
      if text.to_s.strip.empty?
        VKApi.send(peer_id, 'Ответ пустой. Отправьте правильный ответ.', MAIN_KEYBOARD)
        return
      end

      Store.set_user_state(
        user[:vk_id],
        'upload_manual_hint',
        data.merge('answer_text' => text.to_s.strip)
      )
      VKApi.send(peer_id, "Отправьте пояснение/подсказку (или '-' если без подсказки).", MAIN_KEYBOARD)
    end

    def handle_upload_manual_hint(user, text, peer_id, data)
      hint = text.to_s.strip
      hint = nil if hint == '-'

      Store.add_question(
        author_user_id: user[:id],
        category_id: (data['category_id'] || data[:category_id]),
        question_text: data['question_text'] || data[:question_text],
        answer_text: data['answer_text'] || data[:answer_text],
        hint_text: hint,
        source_type: 'user_manual'
      )

      Store.set_user_state(
        user[:vk_id],
        'upload_manual_question',
        {
          category_id: data['category_id'] || data[:category_id],
          category_name: data['category_name'] || data[:category_name]
        }
      )
      VKApi.send(peer_id, "Вопрос сохранен и сразу доступен в тренировке. Отправьте следующий вопрос или напишите 'Меню'.", MAIN_KEYBOARD)
    end

    def handle_upload_file(user, message, peer_id)
      json_payload = extract_json_payload(message)
      unless json_payload
        VKApi.send(peer_id, 'Не удалось прочитать JSON. Пришлите корректный JSON-файл или JSON-массив в тексте.', MAIN_KEYBOARD)
        return
      end

      parsed = parse_upload_items(json_payload)
      unless parsed[:ok]
        VKApi.send(peer_id, "Ошибка JSON: #{parsed[:error]}", MAIN_KEYBOARD)
        return
      end

      result = Store.bulk_add_questions(author_user_id: user[:id], items: parsed[:items])
      skipped = result[:skipped]
      skipped_text = skipped.empty? ? '0' : "#{skipped.size} (индексы: #{skipped.map { |x| x[:index] }.join(', ')})"
      VKApi.send(peer_id, "Импорт завершен.\nДобавлено: #{result[:imported]}\nПропущено: #{skipped_text}", MAIN_KEYBOARD)
      show_menu(user[:vk_id], peer_id, 'Возвращаю в меню после импорта.')
    end

    def start_live_interview(user, peer_id)
      start_live_interview_with_topic(user, peer_id, nil)
    end

    def handle_live_interview_topic(user, text, peer_id)
      if global_menu_selection?(text)
        VKApi.send(
          peer_id,
          'Сначала выберите тему интервью или нажмите «Меню». Кнопки главного меню внизу в этом шаге не переключают режим.',
          INTERVIEW_TOPIC_INLINE_KEYBOARD
        )
        return
      end

      topic = normalize(text)
      topic = nil if topic.empty? || topic == 'пропустить' || topic == 'рандом'
      start_live_interview_with_topic(user, peer_id, topic)
    end

    def start_live_interview_with_topic(user, peer_id, topic)
      session = Store.start_session(user_id: user[:id], mode: 'live_interview')
      first_question = DeepSeekApi.first_interview_question(topic)
      initial_history = [
        { role: 'system', content: 'Ты технический интервьюер. Задавай вопросы и оценивай ответы.' },
        { role: 'assistant', content: first_question }
      ]

      Store.record_interview_turn(
        session_id: session[:id],
        user_id: user[:id],
        role: 'assistant',
        content: first_question,
        feedback_json: {}
      )
      Store.set_user_state(
        user[:vk_id],
        'live_interview',
        {
          session_id: session[:id],
          history: initial_history,
          topic: topic
        }
      )
      topic_line = topic ? "Тема: #{topic}\n" : ''
      VKApi.send(
        peer_id,
        "#{topic_line}Режим живого интервью активирован.\n\nПервый вопрос:\n#{first_question}",
        INTERVIEW_MENU_INLINE_KEYBOARD
      )
    end

    def handle_live_interview(user, text, peer_id, data)
      if stop_interview_command?(text)
        session_id = data['session_id'] || data[:session_id]
        Store.close_session(session_id) if session_id
        show_menu(user[:vk_id], peer_id, 'Интервью завершено.')
        return
      end

      if global_menu_selection?(text)
        VKApi.send(
          peer_id,
          'Сейчас идёт живое интервью — ответьте на вопрос текстом. Чтобы выйти: кнопка «Меню» под вопросом или напишите «Меню»/«Стоп». Кнопки «Тренировка» и др. внизу здесь не переключают режим.',
          INTERVIEW_MENU_INLINE_KEYBOARD
        )
        return
      end

      if text.to_s.strip.empty?
        VKApi.send(peer_id, "Пожалуйста, отправьте содержательный ответ. Для выхода нажмите «Меню» ниже или напишите «Меню».", MENU_REPLY_KEYBOARD)
        return
      end

      history = (data['history'] || data[:history] || []).map do |item|
        { role: item['role'] || item[:role], content: item['content'] || item[:content] }
      end
      history = [{ role: 'system', content: 'Ты технический интервьюер. Задавай вопросы и оценивай ответы.' }] if history.empty?

      evaluation = DeepSeekApi.evaluate_interview_answer(history: history, user_answer: text)
      session_id = data['session_id'] || data[:session_id]

      Store.record_interview_turn(
        session_id: session_id,
        user_id: user[:id],
        role: 'user',
        content: text,
        score: nil,
        feedback_json: {}
      )
      Store.record_interview_turn(
        session_id: session_id,
        user_id: user[:id],
        role: 'assistant',
        content: evaluation[:next_question],
        score: evaluation[:score],
        feedback_json: {
          review: evaluation[:review],
          improvement: evaluation[:improvement]
        }
      )
      Store.bump_interview_stats(user_id: user[:id], score: evaluation[:score])

      updated_history = (
        history +
        [{ role: 'user', content: text }] +
        [{ role: 'assistant', content: evaluation[:next_question] }]
      ).last(20)
      Store.set_user_state(
        user[:vk_id],
        'live_interview',
        { session_id: session_id, history: updated_history }
      )

      VKApi.send(
        peer_id,
        "Оценка: #{evaluation[:score]}/10\nРевью: #{evaluation[:review]}\nЧто улучшить: #{evaluation[:improvement]}\n\nСледующий вопрос:\n#{evaluation[:next_question]}",
        INTERVIEW_MENU_INLINE_KEYBOARD
      )
    end

    def show_stats(user, peer_id)
      stats = Store.stats_for_user(user[:id])
      top_categories = Store.top_categories_for_user(user[:id], limit: 3, interview_only: true)
      recent = Store.recent_attempts(user[:id], limit: 3, interview_only: true)

      top_categories_text = top_categories.empty? ? 'Нет данных' : top_categories.map { |row| "- #{row[:name]}: #{row[:attempts_count]}" }.join("\n")
      recent_text = if recent.empty?
                      'Нет попыток'
                    else
                      recent.map { |row| "- [#{row[:category_name]}] #{row[:score]}/10: #{row[:question_text][0..45]}" }.join("\n")
                    end

      text = <<~TEXT
        Ваша статистика (только живое интервью):
        Ответов: #{stats[:interview_answers_count]}, средний score #{stats[:interview_avg_score]}

        Топ категорий по интервью:
        #{top_categories_text}

        Последние ответы в интервью:
        #{recent_text}
      TEXT

      Store.set_user_state(user[:vk_id], 'menu')
      VKApi.send(peer_id, text.strip, MAIN_KEYBOARD)
    end

    def show_menu(vk_id, peer_id, prefix = nil)
      Store.set_user_state(vk_id, 'menu')
      menu_text = [prefix, "Выберите режим:\n- Тренировка\n- Загрузить вопросы\n- Живое интервью\n- Статистика"].compact.join("\n\n")
      VKApi.send(peer_id, menu_text, MAIN_KEYBOARD)
    end

    def evaluate_answer(user_answer, reference_answer)
      user_tokens = tokenize(user_answer)
      ref_tokens = tokenize(reference_answer)
      return [1, 'Ответ слишком короткий. Добавьте ключевые термины и примеры.'] if user_tokens.empty?
      return [5, 'Эталонный ответ пуст, оценка выставлена базово.'] if ref_tokens.empty?

      overlap = user_tokens & ref_tokens
      ratio = overlap.size.to_f / ref_tokens.size.to_f
      score = (ratio * 10).round.clamp(1, 10)

      feedback = if score >= 8
                   'Сильный ответ: покрыты основные ключевые пункты.'
                 elsif score >= 5
                   'Неплохо, но стоит добавить больше технической конкретики.'
                 else
                   'Ответ слишком общий. Добавьте точные термины и практические детали.'
                 end
      [score, feedback]
    end

    def tokenize(text)
      text.to_s.downcase.scan(/[a-zа-яё0-9_]+/i).select { |word| word.length > 2 }.uniq
    end

    def extract_json_payload(message)
      text = message['text'].to_s.strip
      return text unless text.empty?

      VKApi.fetch_json_from_message_attachment(message)
    end

    def parse_upload_items(raw_json)
      parsed = JSON.parse(raw_json)
      items = parsed.is_a?(Array) ? parsed : [parsed]

      normalized = items.map do |item|
        {
          category: item['category'] || item[:category],
          question: item['question'] || item[:question],
          answer: item['answer'] || item[:answer],
          hint: item['hint'] || item[:hint]
        }
      end

      { ok: true, items: normalized }
    rescue JSON::ParserError => e
      { ok: false, error: e.message, items: [] }
    end

    def normalize(text)
      text.to_s.strip.downcase
    end

    def normalize_training_category_input(text)
      raw = text.to_s.strip
      return raw if raw.empty?

      key = normalize(raw).delete(' ')
      return 'Data Science' if key == 'datascience'

      raw
    end

    def start_command?(text)
      %w[/start start начать].include?(normalize(text))
    end

    def menu_command?(text)
      %w[/menu menu меню в_меню].include?(normalize(text))
    end

    def next_command?(text)
      %w[/next дальше next].include?(normalize(text))
    end

    def stop_interview_command?(text)
      %w[стоп stop /stop menu меню /menu].include?(normalize(text))
    end

    def global_menu_selection?(text)
      ['тренировка', 'загрузить вопросы', 'живое интервью', 'статистика'].include?(normalize(text))
    end

    def interview_blocking_state?(state)
      %w[live_interview live_interview_topic].include?(state)
    end

    def abandon_current_activity!(user, state, data)
      return if state == 'menu'

      case state
      when 'live_interview'
        session_id = data['session_id'] || data[:session_id]
        Store.close_session(session_id) if session_id
      when 'training_answer'
        session_id = data['session_id'] || data[:session_id]
        Store.close_session(session_id) if session_id
        # live_interview_topic, training_category, upload_* — отдельной активной сессии нет или не требуется закрытие
      end
    end

    def training_hint_command?(text)
      normalize(text) == 'подсказка'
    end

    def training_show_answer_command?(text)
      normalize(text) == 'показать ответ'
    end

    def answer_message(question)
      message = +"Правильный ответ: #{question[:answer_text]}\n"
      message << "Подсказка: #{question[:hint_text]}\n\n" if question[:hint_text].to_s.strip != ''
      message << 'Выберите действие ниже.'
      message
    end

    def inline_keyboard(labels, columns: 2)
      rows = labels.each_slice(columns).map do |slice|
        slice.map do |label|
          {
            action: { type: 'text', label: label },
            color: 'primary'
          }
        end
      end

      {
        inline: true,
        buttons: rows
      }
    end

    def reply_keyboard(labels, columns: 2, one_time: true)
      rows = labels.each_slice(columns).map do |slice|
        slice.map do |label|
          {
            action: { type: 'text', label: label },
            color: 'primary'
          }
        end
      end

      {
        one_time: one_time,
        buttons: rows
      }
    end
  end
end