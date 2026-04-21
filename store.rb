require 'json'
require 'pg'

module Store
  class << self
    def bootstrap!
      migrate!
      seed!
    end

    def upsert_user(vk_id)
      row = one(
        <<~SQL,
          INSERT INTO users (vk_id)
          VALUES ($1)
          ON CONFLICT (vk_id)
          DO UPDATE SET updated_at = NOW()
          RETURNING id, vk_id, state, state_data
        SQL
        [vk_id]
      )
      ensure_stats_row(row['id'])
      symbolize_keys(row)
    end

    def user_state(vk_id)
      row = one("SELECT state, state_data FROM users WHERE vk_id = $1", [vk_id])
      return { state: 'menu', data: {} } unless row

      {
        state: row['state'] || 'menu',
        data: parse_json(row['state_data'])
      }
    end

    def set_user_state(vk_id, state, data = {})
      query(
        <<~SQL,
          UPDATE users
          SET state = $2,
              state_data = $3::jsonb,
              updated_at = NOW()
          WHERE vk_id = $1
        SQL
        [vk_id, state, JSON.generate(data || {})]
      )
    end

    def categories
      all("SELECT id, slug, name FROM categories ORDER BY name ASC").map { |row| symbolize_keys(row) }
    end

    def category_by_text(input)
      text = input.to_s.strip
      return nil if text.empty?

      row = one(
        <<~SQL,
          SELECT id, slug, name
          FROM categories
          WHERE LOWER(name) = LOWER($1)
             OR LOWER(slug) = LOWER($1)
          LIMIT 1
        SQL
        [text]
      )
      symbolize_keys(row)
    end

    def find_or_create_category(name_or_slug)
      raw = name_or_slug.to_s.strip
      return nil if raw.empty?

      slug = normalize_slug(raw)
      pretty_name = raw.split.map(&:capitalize).join(' ')

      row = one(
        <<~SQL,
          INSERT INTO categories (slug, name)
          VALUES ($1, $2)
          ON CONFLICT (slug)
          DO UPDATE SET name = categories.name
          RETURNING id, slug, name
        SQL
        [slug, pretty_name]
      )
      symbolize_keys(row)
    end

    def random_question(category_id, exclude_question_id: nil)
      if exclude_question_id
        row = one(
          <<~SQL,
            SELECT id, category_id, question_text, answer_text, hint_text
            FROM questions
            WHERE category_id = $1
              AND id <> $2
            ORDER BY RANDOM()
            LIMIT 1
          SQL
          [category_id, exclude_question_id]
        )
      else
        row = one(
          <<~SQL,
            SELECT id, category_id, question_text, answer_text, hint_text
            FROM questions
            WHERE category_id = $1
            ORDER BY RANDOM()
            LIMIT 1
          SQL
          [category_id]
        )
      end
      symbolize_keys(row)
    end

    def question_by_id(question_id)
      row = one(
        "SELECT id, category_id, question_text, answer_text, hint_text FROM questions WHERE id = $1 LIMIT 1",
        [question_id]
      )
      symbolize_keys(row)
    end

    def start_session(user_id:, mode:, category_id: nil, current_question_id: nil)
      query(
        <<~SQL,
          UPDATE sessions
          SET status = 'closed',
              ended_at = NOW()
          WHERE user_id = $1 AND mode = $2 AND status = 'active'
        SQL
        [user_id, mode]
      )

      row = one(
        <<~SQL,
          INSERT INTO sessions (user_id, mode, status, category_id, current_question_id)
          VALUES ($1, $2, 'active', $3, $4)
          RETURNING id, user_id, mode, status, category_id, current_question_id
        SQL
        [user_id, mode, category_id, current_question_id]
      )
      symbolize_keys(row)
    end

    def active_session(user_id:, mode:)
      row = one(
        <<~SQL,
          SELECT id, user_id, mode, status, category_id, current_question_id
          FROM sessions
          WHERE user_id = $1 AND mode = $2 AND status = 'active'
          ORDER BY started_at DESC
          LIMIT 1
        SQL
        [user_id, mode]
      )
      symbolize_keys(row)
    end

    def update_session_question(session_id, question_id)
      query("UPDATE sessions SET current_question_id = $2 WHERE id = $1", [session_id, question_id])
    end

    def close_session(session_id)
      query(
        "UPDATE sessions SET status = 'closed', ended_at = NOW() WHERE id = $1 AND status = 'active'",
        [session_id]
      )
    end

    def record_attempt(session_id:, user_id:, question_id:, user_answer:, score:, feedback:)
      query(
        <<~SQL,
          INSERT INTO attempts (session_id, user_id, question_id, user_answer, score, feedback)
          VALUES ($1, $2, $3, $4, $5, $6)
        SQL
        [session_id, user_id, question_id, user_answer, score, feedback]
      )
    end

    def record_interview_turn(session_id:, user_id:, role:, content:, score: nil, feedback_json: {})
      query(
        <<~SQL,
          INSERT INTO interview_turns (session_id, user_id, role, content, score, feedback_json)
          VALUES ($1, $2, $3, $4, $5, $6::jsonb)
        SQL
        [session_id, user_id, role, content, score, JSON.generate(feedback_json || {})]
      )
    end

    def bump_interview_stats(user_id:, score:)
      query(
        <<~SQL,
          INSERT INTO user_stats (user_id, interview_answers_count, interview_score_sum, last_activity_at)
          VALUES ($1, 1, $2, NOW())
          ON CONFLICT (user_id)
          DO UPDATE SET interview_answers_count = user_stats.interview_answers_count + 1,
                        interview_score_sum = user_stats.interview_score_sum + EXCLUDED.interview_score_sum,
                        last_activity_at = NOW()
        SQL
        [user_id, score]
      )
    end

    def add_question(author_user_id:, category_id:, question_text:, answer_text:, hint_text:, source_type:)
      one(
        <<~SQL,
          INSERT INTO questions (category_id, question_text, answer_text, hint_text, source_type, author_user_id)
          VALUES ($1, $2, $3, $4, $5, $6)
          RETURNING id
        SQL
        [category_id, question_text, answer_text, hint_text, source_type, author_user_id]
      )
    end

    def bulk_add_questions(author_user_id:, items:)
      imported = 0
      skipped = []

      items.each_with_index do |item, idx|
        category = find_or_create_category(item[:category].to_s)
        question = item[:question].to_s.strip
        answer = item[:answer].to_s.strip
        hint = item[:hint].to_s.strip

        if category.nil? || question.empty? || answer.empty?
          skipped << { index: idx, reason: 'missing_fields' }
          next
        end

        add_question(
          author_user_id: author_user_id,
          category_id: category[:id],
          question_text: question,
          answer_text: answer,
          hint_text: hint.empty? ? nil : hint,
          source_type: 'user_file'
        )
        imported += 1
      rescue StandardError => e
        skipped << { index: idx, reason: e.message }
      end

      { imported: imported, skipped: skipped }
    end

    def stats_for_user(user_id)
      row = one(
        <<~SQL,
          SELECT interview_answers_count,
                 interview_score_sum,
                 last_activity_at
          FROM user_stats
          WHERE user_id = $1
        SQL
        [user_id]
      )

      return default_stats unless row

      interview_count = row['interview_answers_count'].to_i

      {
        training_attempts_count: 0,
        training_avg_score: 0.0,
        interview_answers_count: interview_count,
        interview_avg_score: average(row['interview_score_sum'], interview_count),
        last_activity_at: row['last_activity_at']
      }
    end

    def top_categories_for_user(user_id, limit: 3, interview_only: false)
      return top_categories_interview_turns(user_id, limit) if interview_only

      all(
        <<~SQL,
          SELECT c.name, COUNT(*) AS attempts_count
          FROM attempts a
          JOIN questions q ON q.id = a.question_id
          JOIN categories c ON c.id = q.category_id
          WHERE a.user_id = $1
          GROUP BY c.id, c.name
          ORDER BY attempts_count DESC, c.name ASC
          LIMIT $2
        SQL
        [user_id, limit]
      ).map { |row| { name: row['name'], attempts_count: row['attempts_count'].to_i } }
    end

    def recent_attempts(user_id, limit: 5, interview_only: false)
      return recent_interview_turns(user_id, limit) if interview_only

      all(
        <<~SQL,
          SELECT c.name AS category_name,
                 q.question_text,
                 a.score,
                 a.created_at
          FROM attempts a
          JOIN questions q ON q.id = a.question_id
          JOIN categories c ON c.id = q.category_id
          WHERE a.user_id = $1
          ORDER BY a.created_at DESC
          LIMIT $2
        SQL
        [user_id, limit]
      ).map do |row|
        {
          category_name: row['category_name'],
          question_text: row['question_text'],
          score: row['score'].to_i,
          created_at: row['created_at']
        }
      end
    end

    private

    def top_categories_interview_turns(user_id, limit)
      row = one(
        <<~SQL,
          SELECT COUNT(*) AS cnt
          FROM interview_turns u
          INNER JOIN sessions s ON s.id = u.session_id AND s.mode = 'live_interview'
          WHERE u.user_id = $1 AND u.role = 'user'
        SQL
        [user_id]
      )
      cnt = row ? row['cnt'].to_i : 0
      return [] if cnt.zero?

      [{ name: 'Интервью', attempts_count: cnt }].take(limit)
    end

    def recent_interview_turns(user_id, limit)
      all(
        <<~SQL,
          SELECT u.content AS user_answer,
                 u.created_at AS answered_at,
                 u.session_id,
                 a.score AS eval_score,
                 a.content AS assistant_reply
          FROM interview_turns u
          INNER JOIN sessions s ON s.id = u.session_id AND s.mode = 'live_interview'
          LEFT JOIN LATERAL (
            SELECT score, content
            FROM interview_turns
            WHERE session_id = u.session_id
              AND role = 'assistant'
              AND created_at > u.created_at
            ORDER BY created_at ASC
            LIMIT 1
          ) a ON TRUE
          WHERE u.user_id = $1 AND u.role = 'user'
          ORDER BY u.created_at DESC
          LIMIT $2
        SQL
        [user_id, limit]
      ).map do |row|
        score = row['eval_score'].nil? ? 0 : row['eval_score'].to_i
        snippet = row['user_answer'].to_s.strip[0, 120]
        snippet = 'Ответ в интервью' if snippet.empty?
        {
          category_name: 'Интервью',
          question_text: snippet,
          score: score,
          created_at: row['answered_at']
        }
      end
    end

    def connection
      @connection ||= PG.connect(database_url)
    end

    def database_url
      ENV['DATABASE_URL'] || ENV['POSTGRES_URL'] || 'postgres://postgres:postgres@127.0.0.1:5432/vk_bot'
    end

    def query(sql, params = [])
      connection.exec_params(sql, params)
    rescue PG::Error => e
      puts "DB error: #{e.message}"
      raise
    end

    def one(sql, params = [])
      result = query(sql, params)
      result.ntuples.zero? ? nil : result.first
    end

    def all(sql, params = [])
      query(sql, params).to_a
    end

    def migrate!
      migration_path = File.join(__dir__, 'db', 'migrations', '001_init.sql')
      sql = File.read(migration_path)
      connection.exec(sql)
    rescue PG::ConnectionBad => e
      raise PG::ConnectionBad, "#{e.message}\nSet DATABASE_URL in .env, e.g. postgres://postgres:postgres@127.0.0.1:5432/vk_bot"
    end

    def seed!
      seed_path = File.join(__dir__, 'db', 'seeds.sql')
      sql = File.read(seed_path)
      connection.exec(sql)
    end

    def parse_json(value)
      return {} if value.nil? || value.to_s.empty?
      return value if value.is_a?(Hash)

      JSON.parse(value)
    rescue JSON::ParserError
      {}
    end

    def normalize_slug(text)
      text.downcase.gsub(/[^a-z0-9а-яё]+/i, '_').gsub(/\A_+|_+\z/, '')
    end

    def ensure_stats_row(user_id)
      query(
        <<~SQL,
          INSERT INTO user_stats (user_id)
          VALUES ($1)
          ON CONFLICT (user_id) DO NOTHING
        SQL
        [user_id]
      )
    end

    def symbolize_keys(row)
      return nil unless row

      row.each_with_object({}) { |(k, v), memo| memo[k.to_sym] = v }
    end

    def default_stats
      {
        training_attempts_count: 0,
        training_avg_score: 0.0,
        interview_answers_count: 0,
        interview_avg_score: 0.0,
        last_activity_at: nil
      }
    end

    def average(sum_value, count)
      return 0.0 if count.to_i.zero?

      (sum_value.to_f / count.to_f).round(2)
    end
  end
end