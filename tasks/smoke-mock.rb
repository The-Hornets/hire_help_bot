require 'json'
require_relative '../bot'

$state = {}
$users = {}
$categories = [{ id: 1, slug: 'backend', name: 'Backend' }]
$questions = [
  {
    id: 1,
    category_id: 1,
    question_text: 'What is API?',
    answer_text: 'application programming interface',
    hint_text: 'abbr'
  }
]
$sessions = []
$attempts = []
$stats = {}

module Store
  class << self
    def upsert_user(vk_id)
      $users[vk_id] ||= { id: $users.size + 1, vk_id: vk_id }
    end

    def user_state(vk_id)
      $state[vk_id] || { state: 'menu', data: {} }
    end

    def set_user_state(vk_id, state, data = {})
      $state[vk_id] = { state: state, data: data }
    end

    def categories
      $categories
    end

    def category_by_text(input)
      categories.find { |cat| cat[:name].casecmp?(input.to_s) || cat[:slug].casecmp?(input.to_s) }
    end

    def find_or_create_category(name)
      existing = category_by_text(name)
      return existing if existing

      category = { id: $categories.size + 1, slug: name.to_s.downcase, name: name.to_s }
      $categories << category
      category
    end

    def start_session(user_id:, mode:, category_id: nil, current_question_id: nil)
      session = {
        id: $sessions.size + 1,
        user_id: user_id,
        mode: mode,
        status: 'active',
        category_id: category_id,
        current_question_id: current_question_id
      }
      $sessions << session
      session
    end

    def update_session_question(session_id, question_id)
      session = $sessions.find { |item| item[:id] == session_id }
      session[:current_question_id] = question_id if session
    end

    def random_question(category_id, exclude_question_id: nil)
      $questions.find do |item|
        item[:category_id] == category_id && (exclude_question_id.nil? || item[:id] != exclude_question_id)
      end
    end

    def question_by_id(question_id)
      $questions.find { |item| item[:id].to_i == question_id.to_i }
    end

    def record_attempt(session_id:, user_id:, question_id:, user_answer:, score:, feedback:)
      session = $sessions.find { |item| item[:id].to_i == session_id.to_i }
      mode = session ? session[:mode] : 'training'
      $attempts << {
        session_id: session_id,
        user_id: user_id,
        question_id: question_id,
        user_answer: user_answer,
        score: score,
        feedback: feedback,
        mode: mode
      }
    end

    def add_question(author_user_id:, category_id:, question_text:, answer_text:, hint_text:, source_type:)
      $questions << {
        id: $questions.size + 1,
        category_id: category_id,
        question_text: question_text,
        answer_text: answer_text,
        hint_text: hint_text
      }
    end

    def bulk_add_questions(author_user_id:, items:)
      items.each do |item|
        category = find_or_create_category(item[:category])
        add_question(
          author_user_id: author_user_id,
          category_id: category[:id],
          question_text: item[:question],
          answer_text: item[:answer],
          hint_text: item[:hint],
          source_type: 'user_file'
        )
      end
      { imported: items.size, skipped: [] }
    end

    def close_session(_session_id); end

    def record_interview_turn(**_kwargs); end

    def bump_interview_stats(user_id:, score:)
      $stats[user_id] ||= { interview_count: 0, interview_sum: 0 }
      $stats[user_id][:interview_count] += 1
      $stats[user_id][:interview_sum] += score
    end

    def stats_for_user(user_id)
      stat = $stats[user_id] || { interview_count: 0, interview_sum: 0 }
      {
        training_attempts_count: 0,
        training_avg_score: 0.0,
        interview_answers_count: stat[:interview_count],
        interview_avg_score: average(stat[:interview_sum], stat[:interview_count]),
        last_activity_at: nil
      }
    end

    def top_categories_for_user(_user_id, limit: 3, interview_only: false)
      list = interview_only ? $attempts.select { |a| a[:mode] == 'live_interview' } : $attempts
      label = interview_only ? 'Интервью' : 'Backend'
      return [] if list.empty?

      [{ name: label, attempts_count: list.size }].take(limit)
    end

    def recent_attempts(_user_id, limit: 3, interview_only: false)
      list = interview_only ? $attempts.select { |a| a[:mode] == 'live_interview' } : $attempts
      label = interview_only ? 'Интервью' : 'Backend'
      list.last(limit).map do |attempt|
        {
          category_name: label,
          question_text: begin
                            t = attempt[:user_answer].to_s.strip[0, 120]
                            t.empty? ? 'Mock question' : t
                          end,
          score: attempt[:score],
          created_at: Time.now
        }
      end
    end

    private

    def average(sum, count)
      return 0.0 if count.zero?

      (sum.to_f / count.to_f).round(2)
    end
  end
end

module VKApi
  class << self
    def send(_peer_id, text, _keyboard = nil)
      first_line = text.to_s.lines.first.to_s.strip
      puts "OUT: #{first_line}"
    end

    def fetch_json_from_message_attachment(_message)
      nil
    end
  end
end

module DeepSeekApi
  class << self
    def first_interview_question(_topic = nil)
      'Explain CAP theorem.'
    end

    def evaluate_interview_answer(history:, user_answer:)
      {
        score: 7,
        review: "history=#{history.size}, answer=#{user_answer.size}",
        improvement: 'Добавьте пример из практики.',
        next_question: 'What is database indexing?'
      }
    end
  end
end

def msg(text, from: 1, peer: 1, attachments: [])
  {
    'text' => text,
    'from_id' => from,
    'peer_id' => peer,
    'attachments' => attachments
  }
end

Bot.dispatch(msg('Начать'))
Bot.dispatch(msg('Тренировка'))
Bot.dispatch(msg('Backend'))
Bot.dispatch(msg('Подсказка'))
Bot.dispatch(msg('Показать ответ'))
Bot.dispatch(msg('Дальше'))
Bot.dispatch(msg('Загрузить вопросы'))
Bot.dispatch(msg('Вручную'))
Bot.dispatch(msg('Backend'))
Bot.dispatch(msg('Что такое кеш?'))
Bot.dispatch(msg('Быстрое промежуточное хранилище'))
Bot.dispatch(msg('Уменьшает задержки'))
Bot.dispatch(msg('Живое интервью'))
Bot.dispatch(msg('Мой ответ интервьюеру'))
Bot.dispatch(msg('Стоп'))
Bot.dispatch(msg('Статистика'))

puts 'SMOKE_OK'
