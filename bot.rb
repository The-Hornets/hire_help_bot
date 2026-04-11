require_relative 'store'
require_relative 'apis/vk'
require_relative 'apis/deepseek'

module Bot
  def self.dispatch(vk_id, text, peer_id)
    Store.upsert_user(vk_id)
    state = Store.get_state(vk_id)
    send("handle_#{state}", vk_id, text, peer_id)
  rescue NoMethodError
    VKApi.send(peer_id, "⚠️ Неизвестная команда. Отправьте /start")
    Store.set_state(vk_id, 'menu')
  end

  def self.handle_menu(vk_id, text, peer_id)
    return Store.set_state(vk_id, 'menu') && VKApi.send(peer_id, "📌 Меню:\n1️⃣ Тренировка\n2️⃣ Интервью\n3️⃣ Статистика") if text == '/start'
    text == '2️⃣ Интервью' ? start_interview(vk_id, peer_id) : VKApi.send(peer_id, "Выбрано: #{text}")
  end

  def self.start_interview(vk_id, peer_id)
    Store.set_state(vk_id, 'interview', history: [{ role: 'system', content: 'Ты технический интервьюер.' }])
    VKApi.send(peer_id, "🎤 Началось живое интервью. Задавай вопросы или отвечай.")
  end

  def self.handle_interview(vk_id, text, peer_id)
    data = JSON.parse(Store.get("data:#{vk_id}") || '{}', symbolize_names: true)
    data[:history] << { role: 'user', content: text }
    reply = DeepSeekApi.chat(data[:history])
    data[:history] << { role: 'assistant', content: reply }
    Store.set_state(vk_id, 'interview', data)
    VKApi.send(peer_id, reply)
  end
end